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
		_, err := vc.Write([]byte("hello"))
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
	if first[16] != visionCommandEnd {
		t.Fatalf("command = %d, want end", first[16])
	}
	contentLen := int(binary.BigEndian.Uint16(first[17:19]))
	paddingLen := int(binary.BigEndian.Uint16(first[19:21]))
	if contentLen != 5 || paddingLen != 0 {
		t.Fatalf("first frame content/padding = %d/%d, want 5/0", contentLen, paddingLen)
	}
	content := make([]byte, contentLen)
	if _, err := io.ReadFull(server, content); err != nil {
		t.Fatal(err)
	}
	if string(content) != "hello" {
		t.Fatalf("content = %q", content)
	}
	raw := make([]byte, 4)
	if _, err := io.ReadFull(server, raw); err != nil {
		t.Fatal(err)
	}
	if string(raw) != "tail" {
		t.Fatalf("raw tail = %q", raw)
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
