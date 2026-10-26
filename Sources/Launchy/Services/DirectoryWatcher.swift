import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 监听几个文件夹里的「增、删、改名」，有变化时（防抖后）在主线程回调一次。
/// 用 DispatchSource 监听文件夹本身，不轮询、不常驻线程，几乎不占资源。
/// 只是「读」文件夹事件，从不修改任何文件。
final class DirectoryWatcher {
    private let urls: [URL]
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?

    init(_ urls: [URL], debounce: TimeInterval = 0.6, onChange: @escaping () -> Void) {
        self.urls = urls
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        pending?.cancel()
        sources.values.forEach { $0.cancel() }
    }

    /// 给还没在监听的文件夹挂上监听。文件夹暂时不存在（例如还没有 ~/Library/LaunchAgents）就先跳过，
    /// 下次调用时再试。必须在主线程调用。
    func start() {
        for url in urls where sources[url.path] == nil {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            let path = url.path
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                // 文件夹本身被删除或改名：停掉旧的监听，下次 start() 时重新挂
                if !source.data.intersection([.delete, .rename]).isEmpty {
                    source.cancel()
                    self.sources[path] = nil
                }
                self.scheduleChange()
            }
            source.setCancelHandler { close(fd) }
            sources[path] = source
            source.resume()
        }
    }

    /// 安装程序往往一次写好几个文件，合并成一次刷新
    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
