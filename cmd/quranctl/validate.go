// validate.go — `quranctl validate <path>`, a 1:1 replacement for the plugin's
// validate_media.sh gate. Exit 0 = valid media, 1 = invalid, 2 = usage error.
package main

import (
	"fmt"
	"os"

	"quranproxyd/internal/mediavalidate"
)

func cmdValidate(args []string) int {
	if len(args) != 1 || args[0] == "" {
		fmt.Fprintln(os.Stderr, "usage: quranctl validate <file>")
		return 2
	}
	if err := mediavalidate.Validate(args[0]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}
