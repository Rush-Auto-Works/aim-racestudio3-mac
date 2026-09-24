// rs3-engine — executable of the nested "RaceStudio 3.app" helper. It only execs rs3-engine.sh
// from the helper's Resources; the script holds the real launch logic and the reason it exists.
// A compiled executable (not the script itself) so the helper signs and notarizes like any app.
import Foundation

let script = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/rs3-engine.sh").path
var argv: [UnsafeMutablePointer<CChar>?] = ["/bin/bash", script].map { strdup($0) } + [nil]
execv("/bin/bash", &argv)
perror("rs3-engine: execv /bin/bash")
exit(127)
