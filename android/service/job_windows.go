//go:build windows

package main

import (
	"fmt"
	"io"
	"syscall"
	"unsafe"
)

const (
	jobObjectExtendedLimitInformationClass = 9
	jobObjectLimitKillOnJobClose           = 0x00002000
	processSetQuota                        = 0x0100
	processTerminate                       = 0x0001
)

type jobObjectBasicLimitInformation struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

type ioCounters struct {
	ReadOperationCount  uint64
	WriteOperationCount uint64
	OtherOperationCount uint64
	ReadTransferCount   uint64
	WriteTransferCount  uint64
	OtherTransferCount  uint64
}

type jobObjectExtendedLimitInformation struct {
	BasicLimitInformation jobObjectBasicLimitInformation
	IoInfo                ioCounters
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

type windowsJob struct {
	handle syscall.Handle
}

func (j *windowsJob) Close() error {
	if j == nil || j.handle == 0 {
		return nil
	}
	err := syscall.CloseHandle(j.handle)
	j.handle = 0
	return err
}

var (
	kernel32                     = syscall.NewLazyDLL("kernel32.dll")
	procCreateJobObjectW         = kernel32.NewProc("CreateJobObjectW")
	procSetInformationJobObject  = kernel32.NewProc("SetInformationJobObject")
	procAssignProcessToJobObject = kernel32.NewProc("AssignProcessToJobObject")
	procOpenProcess              = kernel32.NewProc("OpenProcess")
)

func attachKillOnCloseJob(pid int) (io.Closer, error) {
	jobRaw, _, createErr := procCreateJobObjectW.Call(0, 0)
	if jobRaw == 0 {
		return nil, fmt.Errorf("CreateJobObjectW: %w", createErr)
	}
	job := &windowsJob{handle: syscall.Handle(jobRaw)}
	cleanup := true
	defer func() {
		if cleanup {
			_ = job.Close()
		}
	}()

	info := jobObjectExtendedLimitInformation{}
	info.BasicLimitInformation.LimitFlags = jobObjectLimitKillOnJobClose
	ok, _, setErr := procSetInformationJobObject.Call(
		uintptr(job.handle),
		uintptr(jobObjectExtendedLimitInformationClass),
		uintptr(unsafe.Pointer(&info)),
		unsafe.Sizeof(info),
	)
	if ok == 0 {
		return nil, fmt.Errorf("SetInformationJobObject: %w", setErr)
	}

	processRaw, _, openErr := procOpenProcess.Call(
		uintptr(processSetQuota|processTerminate),
		0,
		uintptr(uint32(pid)),
	)
	if processRaw == 0 {
		return nil, fmt.Errorf("OpenProcess(%d): %w", pid, openErr)
	}
	processHandle := syscall.Handle(processRaw)
	defer syscall.CloseHandle(processHandle)

	ok, _, assignErr := procAssignProcessToJobObject.Call(uintptr(job.handle), uintptr(processHandle))
	if ok == 0 {
		return nil, fmt.Errorf("AssignProcessToJobObject: %w", assignErr)
	}

	cleanup = false
	return job, nil
}
