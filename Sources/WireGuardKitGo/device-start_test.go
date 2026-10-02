/* SPDX-License-Identifier: MIT */

package main

import (
	"errors"
	"testing"
)

type fakeStartupDevice struct {
	configureError error
	upError        error
	upCalls        int
	closeCalls     int
}

func (dev *fakeStartupDevice) IpcSet(string) error { return dev.configureError }
func (dev *fakeStartupDevice) Up() error {
	dev.upCalls++
	return dev.upError
}
func (dev *fakeStartupDevice) Close() { dev.closeCalls++ }

func TestStartConfiguredDevice(t *testing.T) {
	failure := errors.New("failed")
	cases := []struct {
		name           string
		configureError error
		upError        error
		wantUpCalls    int
		wantCloseCalls int
		wantError      error
	}{
		{name: "configuration failure", configureError: failure, wantCloseCalls: 1, wantError: failure},
		{name: "startup failure", upError: failure, wantUpCalls: 1, wantCloseCalls: 1, wantError: failure},
		{name: "success", wantUpCalls: 1},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			dev := &fakeStartupDevice{configureError: test.configureError, upError: test.upError}
			err := startConfiguredDevice(dev, "test configuration")
			if !errors.Is(err, test.wantError) || dev.upCalls != test.wantUpCalls || dev.closeCalls != test.wantCloseCalls {
				t.Fatalf("got error %v, Up calls %d, Close calls %d", err, dev.upCalls, dev.closeCalls)
			}
		})
	}
}
