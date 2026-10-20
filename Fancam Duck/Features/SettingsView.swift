import SwiftUI
import StoreKit

struct SettingsView:View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview

    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:0) {
                    NavigationLink {
                        AboutDuckView()
                    } label: {
                        settingsRow("关于直拍鸭",symbol:"info.circle",identifier:"aboutDuck")
                    }
                    Divider().padding(.leading,56)
                    Button {requestReview()} label: {
                        settingsRow("评价",symbol:"star",identifier:"rateDuck")
                    }
                }.buttonStyle(.plain)
                    .modifier(StudioGlassSurface(shape:RoundedRectangle(cornerRadius:24)))
                    .frame(maxWidth:520).padding(24).frame(maxWidth:.infinity)
            }
            .background {StudioBackground()}
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    StudioIcon(symbol:"xmark",label:"关闭设置") {dismiss()}
                        .accessibilityIdentifier("closeSettings")
                }
            }
        }.preferredColorScheme(.dark)
            .presentationDetents([.large])
    }

    private func settingsRow(_ title:String,symbol:String,identifier:String)->some View {
        HStack(spacing:14) {
            Image(systemName:symbol).font(.system(size:20)).frame(width:24)
            Text(title).font(.body)
            Spacer(minLength:8)
            Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }.foregroundStyle(.primary).padding(.horizontal,18).padding(.vertical,18)
            .frame(maxWidth:.infinity,minHeight:60,alignment:.leading).contentShape(Rectangle())
            .accessibilityElement(children:.combine).accessibilityIdentifier(identifier)
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
                Text("选择舞者，让镜头跟上动作。")
                    .font(.body).multilineTextAlignment(.center).padding(.top,8)
                Text("本机处理 · 原片不上传")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing:0) {
                    openSourceLink("开源项目",detail:"WX-DongXing / Fancam-Duck",symbol:"chevron.left.forwardslash.chevron.right",
                                   destination:URL(string:"https://github.com/WX-DongXing/Fancam-Duck")!)
                        .accessibilityIdentifier("sourceRepository")
                    Divider().padding(.leading,56)
                    openSourceLink("开源协议",detail:"AGPL-3.0-only",symbol:"doc.text",
                                   destination:URL(string:"https://github.com/WX-DongXing/Fancam-Duck/blob/main/LICENSE")!)
                        .accessibilityIdentifier("sourceLicense")
                }.modifier(StudioGlassSurface(shape:RoundedRectangle(cornerRadius:24)))
                    .padding(.top,12)
            }.padding(.horizontal,24).padding(.vertical,36).frame(maxWidth:520)
                .frame(maxWidth:.infinity)
        }.background {StudioBackground()}
            .navigationTitle("关于直拍鸭").navigationBarTitleDisplayMode(.inline)
    }
    private func openSourceLink(_ title:String,detail:String,symbol:String,destination:URL)->some View {
        Link(destination:destination) {
            HStack(spacing:14) {
                Image(systemName:symbol).font(.system(size:20)).frame(width:24)
                VStack(alignment:.leading,spacing:5) {
                    Text(title).font(.body)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:8)
                Image(systemName:"arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }.foregroundStyle(.primary).padding(18)
                .frame(maxWidth:.infinity,minHeight:60,alignment:.leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
