import SwiftUI
import AVKit

struct ExportView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var playing = false
    @State private var savingFile=false
    private var completed: Bool { if case .completed = model.phase { true } else { false } }
    var body: some View {
        GeometryReader { geometry in
            #if targetEnvironment(macCatalyst)
            desktopExport
            #else
            VStack(spacing: 12) {
                HStack {
                    StudioIcon(symbol: "chevron.left", label: "返回编辑") { model.backToEditor() }.disabled(model.phase == .exporting)
                    Spacer()
                    Text(completed ? "导出完成" : "导出预览").font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("exportTitle")
                    Spacer()
                    Button { model.goHome() } label: {
                        Text("完成").font(.subheadline.weight(.semibold)).frame(width:44,height:44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(model.phase == .exporting)
                }.padding(.horizontal, 18).frame(height: 52)
                WorkspaceArrangement(size:CGSize(width:geometry.size.width,height:max(1,geometry.size.height-64))) {
                    exportCanvas
                } controls: {
                    if horizontalSizeClass == .regular {
                        VStack(alignment:.leading,spacing:20) {
                            Label(completed ? "成片已就绪" : "输出设置",systemImage:completed ? "checkmark.circle" : "film")
                                .font(.title3.weight(.semibold))
                            Text(completed ? "预览画面后，保存到相册。" : "确认构图与画质，生成最终视频。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Divider()
                            Text(model.project?.settings.resolution.label ?? "").font(.headline).monospacedDigit()
                            Text("保留原音 · 本机处理").font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength:0)
                            actions
                        }.padding(.top,24).padding(.horizontal,16)
                            .background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:28))
                    } else {actions.frame(height:128,alignment:.bottom)}
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
            #endif
        }.background { StudioBackground() }.foregroundStyle(.white).preferredColorScheme(.dark)
            .sheet(isPresented:$savingFile) {if let url=model.outputURL {SaveVideoPicker(url:url)}}
            .onDisappear { model.previewPlayer?.pause() }
            .onChange(of: model.phase) { _, _ in playing = false }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {playing=false;model.previewPlayer?.pause()}
            }
            .onReceive(NotificationCenter.default.publisher(for:.AVPlayerItemDidPlayToEndTime).receive(on:RunLoop.main)) { notification in
                guard let ended=notification.object as? AVPlayerItem,
                      ended === model.previewPlayer?.currentItem else {return}
                playing=false
            }
    }
    #if targetEnvironment(macCatalyst)
    private var desktopExport:some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                Button {model.backToEditor()} label:{Label("返回编辑",systemImage:"chevron.left")}
                    .buttonStyle(DesktopButtonStyle()).disabled(model.phase == .exporting)
                Divider().frame(height:24)
                Text(model.project?.title ?? "成片预览").font(.system(size:14,weight:.semibold)).lineLimit(1)
                Spacer()
                Button("返回项目") {model.goHome()}.buttonStyle(DesktopButtonStyle()).disabled(model.phase == .exporting)
            }.padding(.horizontal,20).frame(height:64).background(DesktopPalette.panel)
            Divider()
            HStack(spacing:0) {
                VStack(spacing:12) {
                    HStack {
                        Label("成片预览",systemImage:"play.rectangle")
                        Spacer()
                        Text("保留原音").foregroundStyle(.secondary)
                    }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,24).frame(height:38)
                    exportCanvas.padding(.bottom,20)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                VStack(alignment:.leading,spacing:24) {
                    VStack(alignment:.leading,spacing:8) {
                        Label(completed ? "视频已生成" : "准备导出",systemImage:completed ? "checkmark.circle.fill" : "film")
                            .font(.system(size:18,weight:.semibold))
                            .accessibilityIdentifier("exportTitle")
                        Text(completed ? "检查成片后，保存到你指定的文件夹。" : "确认画面与输出设置，生成最终视频。")
                            .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    Divider()
                    DesktopSection(title:"输出信息") {
                        DesktopFact(title:"画面比例",value:model.project?.settings.aspectRatio.rawValue ?? "16:9")
                        DesktopFact(title:"分辨率",value:model.project?.settings.resolution.label ?? "")
                        DesktopFact(title:"音频",value:"保留原音")
                        DesktopFact(title:"视频时长",value:((model.project?.settings.end ?? 0)-(model.project?.settings.start ?? 0)).videoTime)
                    }
                    Spacer(minLength:0)
                    actions
                }.padding(20).frame(width:300).background(DesktopPalette.panel)
            }
        }.background(DesktopPalette.background)
    }
    #endif
    private var exportCanvas:some View {
        GeometryReader { canvas in
            let rect = CropGeometry.aspectFit(video: (model.project?.settings.aspectRatio ?? .portrait).size, container: CGSize(width:canvas.size.width,height:max(1,canvas.size.height-44)))
            ZStack {
                Color.black
                if model.isDemo {
                    let source = model.project?.metadata.size ?? CGSize(width: 1920, height: 1080)
                    let settings=model.project?.settings ?? EditSettings()
                    let target=model.project?.target ?? .init(x:0.35,y:0.1,width:0.2,height:0.7)
                    let sample=TargetSample(time:settings.compositionAnchor?.time ?? model.project?.targetTime ?? 0,body:settings.compositionAnchor?.referenceBody ?? target)
                    let crop=CropPlan.make(samples:[sample],source:source,settings:settings).first?.rect ?? CGRect(origin:.zero,size:source)
                    let scale = rect.width / crop.width
                    DemoStage(time: model.currentTime, target: nil)
                        .frame(width: source.width * scale, height: source.height * scale)
                        .offset(x: (source.width / 2 - crop.midX) * scale, y: (source.height / 2 - crop.midY) * scale)
                } else if model.phase == .exporting, let poster = model.exportPoster {
                    Image(decorative: poster, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel("构图预览静帧").accessibilityIdentifier("exportPoster")
                } else if let player = model.previewPlayer {
                    PlayerSurface(player: player)
                }
                if model.phase != .exporting {
                    VStack {
                        Spacer()
                        StudioIcon(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "暂停成片" : "播放成片") {
                            playing.toggle()
                            if playing {
                                if let player = model.previewPlayer, let duration = player.currentItem?.duration.seconds,
                                   duration.isFinite, player.currentTime().seconds >= duration - 0.1 { player.seek(to: .zero) }
                                model.previewPlayer?.play()
                            } else { model.previewPlayer?.pause() }
                        }.padding(.bottom, 14)
                    }.frame(width: rect.width, height: rect.height)
                }
            }.frame(width: rect.width, height: rect.height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.2), lineWidth: 1) }
                .position(x: rect.midX, y: rect.midY)
                .accessibilityElement(children: .contain).accessibilityIdentifier("exportViewport")
            Text("\(model.project?.settings.aspectRatio.rawValue ?? "16:9") · \(model.project?.settings.resolution.label ?? "") · \(((model.project?.settings.end ?? 0) - (model.project?.settings.start ?? 0)).formatted(.number.precision(.fractionLength(1))))秒")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).minimumScaleFactor(0.75)
                .frame(width:canvas.size.width,height:32)
                .position(x:canvas.size.width/2,y:rect.maxY+22)
                .accessibilityIdentifier("exportMetadata")
        }.padding(.horizontal, 28)
    }
    private var qualityMenu: some View {
        Menu {
            Picker("输出分辨率", selection: Binding(get: { model.project?.settings.resolution ?? .init(width:1080,height:1920) }, set: { model.project?.settings.resolution=$0;model.persist() })) {
                ForEach(OutputResolution.available(for:model.project?.metadata ?? VideoProject.demo.metadata,aspect:model.project?.settings.aspectRatio ?? .portrait)) { size in
                    Text(size.label).tag(size)
                }
            }
        } label: {
            actionLabel("输出画质", symbol:"slider.horizontal.3", primary:false)
        }.accessibilityIdentifier("exportResolution")
    }
    private func actionLabel(_ title:String,symbol:String,primary:Bool,enabled:Bool=true) -> some View {
        Label(title,systemImage:symbol)
            .font(primary ? .body.weight(.semibold) : .subheadline)
            .lineLimit(1).minimumScaleFactor(0.75)
            .frame(maxWidth:.infinity).frame(height:primary ? 56 : 48)
            .contentShape(Capsule())
            .modifier(StudioGlassSurface(shape:Capsule(),selected:primary && enabled))
    }
    private var backAction: some View {
        Button { model.backToEditor() } label: {
            actionLabel("返回调整",symbol:"slider.horizontal.3",primary:false)
        }.buttonStyle(.plain).accessibilityIdentifier("exportBack")
    }
    private var actionInset:CGFloat {
        #if targetEnvironment(macCatalyst)
        0
        #else
        24
        #endif
    }
    @ViewBuilder private var actions: some View {
        StudioGlassGroup(spacing:12) {
            VStack(spacing:12) {
                if model.phase == .exporting {
                    VStack(spacing:8) {
                        HStack {
                            Text(model.cancellingExport ? "正在取消导出" : "正在生成视频")
                            Spacer()
                            Text(model.exportProgress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                        }.font(.caption)
                        ProgressView(value:model.exportProgress).tint(.white)
                    }.accessibilityIdentifier("exportProgress")
                    Button { model.cancelExport() } label: {
                        actionLabel(model.cancellingExport ? "正在取消…" : "取消导出",symbol:"xmark",primary:false)
                    }.disabled(model.cancellingExport).accessibilityIdentifier("primaryAction")
                } else if completed {
                    if model.isDemo {
                        Button { model.goHome() } label: {
                            actionLabel("完成演示",symbol:"checkmark",primary:true)
                        }.accessibilityIdentifier("primaryAction")
                    } else {
                        HStack(spacing:12) {
                            backAction
                            if let url=model.outputURL {
                                ShareLink(item:url) { actionLabel("分享",symbol:"square.and.arrow.up",primary:false) }
                                    .accessibilityLabel("分享或保存到文件").accessibilityIdentifier("exportShare")
                            }
                        }
                        #if targetEnvironment(macCatalyst)
                        Button {savingFile=true} label: {
                            actionLabel("保存到文件",symbol:"square.and.arrow.down",primary:true)
                        }.disabled(model.outputURL == nil).keyboardShortcut("s",modifiers:.command)
                            .accessibilityIdentifier("primaryAction")
                        #else
                        Button { Task { await model.saveVideo() } } label: {
                            actionLabel(model.savingToPhotos ? "正在保存…" : (model.savedToPhotos ? "已保存到相册" : "保存到相册"),symbol:model.savedToPhotos ? "checkmark" : "square.and.arrow.down",primary:true,enabled:!model.savedToPhotos && !model.savingToPhotos)
                        }.disabled(model.savedToPhotos || model.savingToPhotos).accessibilityIdentifier("primaryAction")
                        #endif
                    }
                } else {
                    Button { model.export() } label: {
                        actionLabel(model.isDemo ? "体验导出流程" : "开始导出",symbol:"square.and.arrow.up",primary:true)
                    }.accessibilityIdentifier("primaryAction")
                    HStack(spacing:12) { backAction; qualityMenu }
                }
            }.buttonStyle(.plain).frame(maxWidth:.infinity)
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, actionInset).padding(.bottom,12)
            .accessibilityElement(children:.contain).accessibilityIdentifier("exportActions")
    }
}
