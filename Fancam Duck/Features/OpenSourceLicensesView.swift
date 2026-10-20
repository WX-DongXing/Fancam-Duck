import SwiftUI

struct OpenSourceLicensesView:View {
    var body:some View {
        List {
            Section("项目许可") {
                Text("直拍鸭 · Fancam Duck").font(.headline)
                Text("项目原创代码和文档采用 AGPL-3.0-only；第三方内容保留各自许可与版权。")
                license("AGPL-3.0-only",file:"AGPL-3.0")

            }
            Group {
                component("YOLO26s-pose",detail:"人物与姿态检测 · Core ML 转换模型",
                          source:"https://github.com/ultralytics/ultralytics",licenseName:"AGPL-3.0",file:"Ultralytics-AGPL")
                component("OSNet",detail:"人物外观特征 · x0.25 MSMT17 权重及 Core ML 转换模型",
                          source:"https://huggingface.co/kaiyangzhou/osnet",licenseName:"MIT",file:"OSNet-MIT")
                component("TrackTrack",detail:"人物跟踪 · Swift 移植",
                          source:"https://github.com/kamkyu94/TrackTrack",licenseName:"MIT",file:"TrackTrack-MIT")
            }
            Section {
                Text("许可正文与版权声明随应用保存，无需联网即可阅读。访问组件网站需要联网。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background {StudioBackground()}
        .navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
    }

    private func license(_ title:String,file:String)->some View {
        NavigationLink {
            OfflineLicenseView(title:title,file:file)
        } label: {
            Label(title,systemImage:"doc.plaintext")
        }.accessibilityIdentifier("license-\(file)")
    }

    private func component(_ name:String,detail:String,source:String,licenseName:String,file:String)->some View {
        Section(name) {
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            license("\(name) · \(licenseName) 与版权声明",file:file)
            Link("组件来源",destination:URL(string:source)!).font(.subheadline)
        }
    }
}

private struct OfflineLicenseView:View {
    let title:String
    let file:String
    private var text:String? {
        guard let url=Bundle.main.url(forResource:file,withExtension:"txt") else {return nil}
        return try? String(contentsOf:url,encoding:.utf8)
    }

    var body:some View {
        ScrollView {
            Text(text ?? "许可文件无法读取，请重新安装应用或联系支持。")
                .font(.system(.body,design:.monospaced))
                .textSelection(.enabled)
                .frame(maxWidth:.infinity,alignment:.leading)
                .padding(20)
                .accessibilityIdentifier("offlineLicenseText")
        }.background {StudioBackground()}
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
