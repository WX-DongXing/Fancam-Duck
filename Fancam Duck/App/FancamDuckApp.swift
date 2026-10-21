import SwiftUI

@main
struct FancamDuckApp: App {
    @State private var model = AppModel(store: Self.projectStore)
    private static var projectStore:ProjectStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-history") {
            return ProjectStore(directory:FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-UI-History-"+UUID().uuidString))
        }
        #endif
        return .shared
    }
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Group {
                switch model.route {
                case .home: HomeView(model: model)
                case .editor: EditorView(model: model)
                case .export: ExportView(model: model)
                }
            }
            #if targetEnvironment(macCatalyst)
            .background {DesktopWindowConfiguration().frame(width:0,height:0)}
            #endif
            .tint(.primary)
            .background(Color.acBackground)
            .alert("直拍鸭", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("知道了", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-history") { await model.prepareHistoryUITest() }
                #endif
                await model.loadProjects()
                #if DEBUG
                // Reopen a verified original clip for simulator review after automated tests.
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "--review-project"), arguments.indices.contains(index + 1),
                   let project = model.projects.first(where: { $0.id.uuidString == arguments[index + 1] }) {
                    model.open(project)
                }
                #endif
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-review") {model.prepareAnalysisReviewDemo()}
                if ProcessInfo.processInfo.arguments.contains("--demo-composition") {model.prepareCompositionDemo()}
                #endif
                if ProcessInfo.processInfo.arguments.contains("--demo-editor") {
                    model.startDemo()
                    #if DEBUG
                    // Deterministic UI geometry checks without adding controls to the product.
                    let sourceSize: CGSize
                    switch ProcessInfo.processInfo.environment["FANCAM_DUCK_UI_RATIO"] {
                    case "square": sourceSize = CGSize(width: 1080, height: 1080)
                    case "portrait": sourceSize = CGSize(width: 1080, height: 1920)
                    case "ultrawide": sourceSize = CGSize(width: 2560, height: 1080)
                    case "narrow": sourceSize = CGSize(width: 1080, height: 2560)
                    default: sourceSize = CGSize(width: 1920, height: 1080)
                    }
                    model.project?.metadata = VideoMetadata(width: sourceSize.width, height: sourceSize.height, duration: 58.2, frameRate: 30)
                    #endif
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.suspend() } }
        }
    }
}
