//go:build darwin

package main

/*

#cgo CFLAGS: -mmacosx-version-min=10.13 -x objective-c
#cgo LDFLAGS: -framework Cocoa -mmacosx-version-min=10.13

#import <Cocoa/Cocoa.h>

void setAccessoryActivationPolicy() {
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

void setRegularActivationPolicy() {
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
}

void activateThisAppOnDarwin() {
  [NSApp activateIgnoringOtherApps:YES];
}

*/
import "C"

func setAccessoryActivationPolicyOnDarwin() {
	C.setAccessoryActivationPolicy()
}

func setRegularActivationPolicyOnDarwin() {
	C.setRegularActivationPolicy()
}

func activateThisAppOnDarwin() {
	C.activateThisAppOnDarwin()
}
