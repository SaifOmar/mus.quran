// quranctl is the short-lived CLI companion to quranproxyd. It gives the
// mus.quran plugin the same operations the retired shell scripts provided
// (download.sh, cache.sh, validate_media.sh), compiled against the SAME
// internal packages the daemon uses (urlsafety, dialer, mediavalidate, ...) so
// there is exactly one implementation of the fetch/validation policy.
//
// Unlike the daemon it is ephemeral: Service.qml spawns it per operation. It
// has no runtime dependency on quranproxyd being alive, which is what makes it
// a working fallback when the daemon is down.
//
// Subcommands:
//
//	quranctl validate <path>                    # validate_media.sh
//	quranctl download <id> <n> [--server URL]   # download.sh, single file
//	quranctl download <id> --only a,b,c [--server URL]  # download.sh, bulk
//	quranctl remove [--state-dir <dir>] <id> <n>  # cache.sh remove (corrupt file)
//
// Exit codes follow the scripts' contracts: 0 success, 1 operation failed
// (e.g. invalid media, failed download), 2 usage error.
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var code int
	switch os.Args[1] {
	case "validate":
		code = cmdValidate(os.Args[2:])
	case "download":
		code = cmdDownload(os.Args[2:])
	case "remove":
		code = cmdRemove(os.Args[2:], os.Stdout, os.Stderr)
	default:
		fmt.Fprintf(os.Stderr, "quranctl: unknown command %q\n", os.Args[1])
		usage()
		code = 2
	}
	os.Exit(code)
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: quranctl {validate|download|remove} ...")
}
