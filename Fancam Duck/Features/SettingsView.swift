import SwiftUI
import StoreKit

struct SettingsView:View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview

    var body:some View {
        NavigationStack {
            List {
                NavigationLink {
                    AboutDuckView()
                } label: {
                    Label("关于直拍鸭",systemImage:"info.circle")
                }.accessibilityIdentifier("aboutDuck")
                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    Label("开源许可",systemImage:"doc.text")
                }.accessibilityIdentifier("openSourceLicenses")
                Button {requestReview()} label: {
                    Label("评价",systemImage:"star")
                }.accessibilityIdentifier("rateDuck")
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    if #available(iOS 26.0, *) {
                        Button("关闭设置",systemImage:"xmark",role:.close) {dismiss()}
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("closeSettings")
                    } else {
                        Button("关闭设置",systemImage:"xmark") {dismiss()}
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("closeSettings")
                    }
                }
            }
        }.preferredColorScheme(.dark)
            .presentationDetents([.large])
    }

}

private struct AboutDuckView:View {
    private var version:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—"}
    private var build:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—"}
    var body:some View {
        ScrollView {
            VStack(spacing:20) {
                BrandLogo(size:88).accessibilityHidden(true)
                VStack(spacing:8) {
                    Text("直拍鸭").font(.title2.weight(.semibold))
                    Text("Fancam Duck").font(.subheadline).foregroundStyle(.secondary)
                    Text("版本 \(version)（\(build)）").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("appVersion")
                }
                VStack(spacing:12) {
                    Text("选择舞者，让镜头跟上动作。")
                        .font(.body).multilineTextAlignment(.center)
                    Text("本机处理 · 原片不上传")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top,8)
            }.padding(.horizontal,24).padding(.vertical,32).frame(maxWidth:420)
                .frame(maxWidth:.infinity)

        }.background {StudioBackground()}
            .navigationTitle("关于直拍鸭").navigationBarTitleDisplayMode(.inline)
    }
}
