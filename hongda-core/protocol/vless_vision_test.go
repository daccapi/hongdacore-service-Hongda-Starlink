package protocol

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func TestBuildVLESSAddonsVision(t *testing.T) {
	got, err := buildVLESSAddons(vlessFlowVision)
	if err != nil {
		t.Fatal(err)
	}
	want := append([]byte{0x0A, byte(len(vlessFlowVision))}, vlessFlowVision...)
	if !bytes.Equal(got, want) {
		t.Fatalf("addons = %x, want %x", got, want)
	}
}

func TestVLESSVisionConnRoundTrip(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	uuid := bytes.Repeat([]byte{0xAB}, 16)
	vc := newVlessVisionConn(client, uuid)

	writeDone := make(chan error, 1)
	go func() {
		_, err := vc.Write([]byte{0x16, 0x03, 0x03, 0, 1, 0x01})
		if err == nil {
			_, err = vc.Write([]byte{0x17, 0x03, 0x03, 0, 1, 0xAA})
		}
		if err == nil {
			_, err = vc.Write([]byte("tail"))
		}
		writeDone <- err
	}()

	first := make([]byte, visionFirstHeaderLen)
	if _, err := io.ReadFull(server, first); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first[:16], uuid) {
		t.Fatalf("first frame uuid = %x, want %x", first[:16], uuid)
	}
	if first[16] != visionCommandContinue {
		t.Fatalf("command = %d, want continue", first[16])
	}
	contentLen := int(binary.BigEndian.Uint16(first[17:19]))
	paddingLen := int(binary.BigEndian.Uint16(first[19:21]))
	if contentLen != 6 || paddingLen != 0 {
		t.Fatalf("first frame content/padding = %d/%d, want 6/0", contentLen, paddingLen)
	}
	content := make([]byte, contentLen)
	if _, err := io.ReadFull(server, content); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(content, []byte{0x16, 0x03, 0x03, 0, 1, 0x01}) {
		t.Fatalf("content = %x", content)
	}
	second := make([]byte, visionSubHeaderLen)
	if _, err := io.ReadFull(server, second); err != nil {
		t.Fatal(err)
	}
	if second[0] != visionCommandEnd || binary.BigEndian.Uint16(second[1:3]) != 6 {
		t.Fatalf("second frame header = %x", second)
	}
	secondContent := make([]byte, 6)
	if _, err := io.ReadFull(server, secondContent); err != nil {
		t.Fatal(err)
	}
	tail := make([]byte, 4)
	if _, err := io.ReadFull(server, tail); err != nil {
		t.Fatal(err)
	}
	if string(tail) != "tail" {
		t.Fatalf("framed tail = %q", tail)
	}
	if err := <-writeDone; err != nil {
		t.Fatal(err)
	}

	readDone := make(chan error, 1)
	go func() {
		buf := make([]byte, 16)
		n, err := vc.Read(buf)
		if err != nil {
			readDone <- err
			return
		}
		if string(buf[:n]) != "reply" {
			readDone <- io.ErrUnexpectedEOF
			return
		}
		n, err = vc.Read(buf)
		if err != nil {
			readDone <- err
			return
		}
		if string(buf[:n]) != "rawtail" {
			readDone <- io.ErrUnexpectedEOF
			return
		}
		readDone <- nil
	}()

	frame := make([]byte, 0, visionFirstHeaderLen+5)
	frame = append(frame, uuid...)
	frame = append(frame, visionCommandEnd)
	frame = binary.BigEndian.AppendUint16(frame, 5)
	frame = binary.BigEndian.AppendUint16(frame, 0)
	frame = append(frame, "reply"...)
	frame = append(frame, "rawtail"...)
	if _, err := server.Write(frame); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-readDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timeout waiting for vision read")
	}
}
