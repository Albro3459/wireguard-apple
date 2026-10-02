/* SPDX-License-Identifier: MIT */

package main

type startupDevice interface {
	IpcSet(string) error
	Up() error
	Close()
}

func startConfiguredDevice(dev startupDevice, settings string) error {
	if err := dev.IpcSet(settings); err != nil {
		dev.Close()
		return err
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return err
	}
	return nil
}
