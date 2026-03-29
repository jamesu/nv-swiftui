import Foundation
import Darwin

final class DirectoryMonitor {
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var monitoredPath: String?

    deinit {
        stop()
    }

    func startMonitoring(path: String, handler: @escaping @Sendable () -> Void) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard monitoredPath != normalizedPath else { return }

        stop()

        let descriptor = open(normalizedPath, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: DispatchQueue.main
        )

        source.setEventHandler(handler: handler)
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()

        self.fileDescriptor = descriptor
        self.source = source
        self.monitoredPath = normalizedPath
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        monitoredPath = nil
    }
}
