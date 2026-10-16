import SwiftUI

/// 程序入口。
@main
struct LaunchyApp: App {
    @StateObject private var tasks = MyTasksStore()
    @StateObject private var services = ServicesStore()

    var body: some Scene {
        WindowGroup("启动台助手") {
            ContentView()
                .environmentObject(tasks)
                .environmentObject(services)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}
