import SwiftUI
import PhotosUI

struct EditorView: View {
    @Bindable var model: AppModel
    @State private var redactionImageItem: PhotosPickerItem?
    @State private var showRedactionImagePicker=false
    @State private var redactionStrengthEditing=false
    @Namespace private var redactionStyleSelection
    @State private var drawnBox: NormalizedRect?
    @State private var showLeaveConfirmation = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var settingsHeight = 184
    @ScaledMetric(relativeTo: .body) private var shortSettingsHeight = 104
    @Namespace private var aspectSelection
    @Namespace private var redactionSelection
    @Namespace private var toolSelection
    @State private var activeTool: WorkspaceTool?
    @State private var timelineTrimming = false

    private enum WorkspaceTool: String, CaseIterable {
        case selection = "选人", composition = "构图", redaction = "打码"
        var symbol: String {
            switch self {
            case .selection: "person.crop.circle"
            case .composition: "crop"
            case .redaction: "square.on.circle"
            }
        }
    }

    private var isProcessing: Bool {
        switch model.phase { case .processing, .paused: true; default: false }
    }
    private var isBlocked: Bool { model.phase.issue != nil }
    private var people: [(id: Int, number: Int, box: NormalizedRect)] {
        if model.isDemo { return (0..<4).map { (id: $0, number: $0, box: DemoStage.body(index: $0, time: model.currentTime)) } }
        return model.observations.sorted { $0.body.center.x < $1.body.center.x }.enumerated().map { (id: $0.element.id, number: $0.offset, box: $0.element.body) }
    }
    var body: some View {
        GeometryReader { geometry in
            #if targetEnvironment(macCatalyst)
            desktopWorkspace
            #else
            VStack(spacing: 0) {
                header
                WorkspaceArrangement(size:CGSize(width:geometry.size.width,height:max(1,geometry.size.height-52))) {
                    VStack(spacing:0) {
                        sourceStage.accessibilityElement(children:.contain).accessibilityIdentifier("editorStage")
                        if usesExpandedWorkspace && !isBlocked && !model.manualSelection {editorTimeline.padding(.bottom,12)}
                    }
                } controls: {
                    if usesExpandedWorkspace {expandedControls}
                    else {
                        VStack(spacing:0) {
                            if isBlocked || model.manualSelection {
                                recoveryDock.frame(height:180,alignment:.bottom)
                            } else {
                                editorTimeline
                                if let tool=activeTool,!isProcessing {
                                    inlineSettings(tool)
                                        .frame(height:tool == .selection ? min(shortSettingsHeight,geometry.size.height*0.25) : tool == .redaction ? min(164,geometry.size.height*0.30) : min(settingsHeight,208,geometry.size.height*0.38))
                                        .transition(.opacity.combined(with:.move(edge:.bottom)))
                                }
                                bottomToolbar.padding(.top,12).padding(.bottom,8)
                            }
                        }
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: isProcessing)
            #endif
        }
        .background { StudioBackground() }.foregroundStyle(.white).preferredColorScheme(.dark)
        .alert("保存并返回首页？", isPresented: $showLeaveConfirmation) {
            Button("取消", role: .cancel) {}
            Button("保存并返回") { model.goHome() }
        } message: { Text("当前任务将暂停，可以在最近项目中重新打开。") }
        .photosPicker(isPresented:$showRedactionImagePicker,selection:$redactionImageItem,matching:.images)
        .task(id:redactionImageItem) {
            guard let item=redactionImageItem else {return}
            do {
                if let data=try await item.loadTransferable(type:Data.self),!Task.isCancelled {await model.importRedactionImage(data)}
                if !Task.isCancelled {redactionImageItem=nil}
            } catch {if !Task.isCancelled {model.errorMessage="图片读取失败，请重新选择。"}}
        }
        .onChange(of: model.phase) { _, phase in
            if phase != .editing {
                withAnimation(reduceMotion ? nil : .smooth(duration:0.28)) { activeTool = nil }
            }
        }
        .onChange(of: model.compositionEditing) { _, editing in
            if !editing && activeTool == .composition { activeTool = nil }
        }
        .onDisappear { model.player?.pause() }
    }
    #if targetEnvironment(macCatalyst)
    private var desktopWorkspace:some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                Button {showLeaveConfirmation=true} label: {Label("项目",systemImage:"chevron.left")}
                    .buttonStyle(DesktopButtonStyle()).accessibilityLabel("返回项目首页")
                Rectangle().fill(DesktopPalette.border).frame(width:1,height:24)
                VStack(alignment:.leading,spacing:3) {
                    Text(model.project?.title ?? "视频编辑").font(.system(size:14,weight:.semibold)).lineLimit(1)
                    Text("FANCAM DUCK  /  视频工作台").font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)
                if isPaused {
                    Button("返回调整") {activeTool=nil;model.returnToEditingFromPause()}
                        .buttonStyle(DesktopButtonStyle()).accessibilityIdentifier("returnToEditingFromPause")
                }
                if !isBlocked && !model.manualSelection {desktopPrimaryAction}
            }.padding(.horizontal,20).frame(height:64).background(DesktopPalette.panel)
            Divider()
            HStack(spacing:0) {
                VStack(spacing:0) {
                    HStack {
                        Label(showsComposition ? "构图预览" : "原片全览",systemImage:showsComposition ? "crop" : "viewfinder")
                        Spacer()
                        Text("\(Int(model.project?.metadata.width ?? 0)) × \(Int(model.project?.metadata.height ?? 0))")
                            .monospacedDigit()
                    }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,20).frame(height:38)
                    sourceStage.padding(.horizontal,8)
                        .accessibilityElement(children:.contain).accessibilityIdentifier("editorStage")
                    Divider()
                    if !isBlocked && !model.manualSelection {
                        editorTimeline.padding(.bottom,16).background(DesktopPalette.panel)
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                desktopInspector.frame(width:300).background(DesktopPalette.panel)
            }
        }.background(DesktopPalette.background)
            .accessibilityElement(children:.contain).accessibilityIdentifier("desktopWorkspace")
    }
    private var desktopPrimaryAction:some View {
        Button {
            if isProcessing {if isPaused {model.resume()} else {model.pause()}}
            else {finishTool(commit:true);model.confirmProcessing()}
        } label: {
            HStack(spacing:12) {
                Image(systemName:isProcessing ? (isPaused ? "play.fill" : "pause.fill") : "sparkles")
                Text(isProcessing ? (isPaused ? "继续处理" : "处理中") : startTitle)
                if isProcessing {Text(processingPercent).monospacedDigit().accessibilityIdentifier("processingProgress")}
            }
        }.buttonStyle(DesktopButtonStyle(prominent:true))
            .disabled(!isProcessing && !canStart).opacity(!isProcessing && !canStart ? 0.45 : 1)
            .accessibilityIdentifier("primaryAction")
            .accessibilityValue(isProcessing ? processingPercent : "")
    }
    private var desktopInspector:some View {
        VStack(alignment:.leading,spacing:20) {
            if isBlocked || model.manualSelection {
                Text(isBlocked ? "确认主角" : "手动框选").font(.system(size:16,weight:.semibold))
                Text(isBlocked ? "跟踪暂时中断。请在原片中重新指定主角，然后继续处理。" : "拖动边框调整区域，尽量包含完整人物。")
                    .font(.system(size:12)).foregroundStyle(.secondary)
                recoveryDock.frame(height:180)
            } else if isProcessing {
                Label(isPaused ? "处理已暂停" : "正在跟随主角",systemImage:isPaused ? "pause.circle" : "viewfinder")
                    .font(.system(size:16,weight:.semibold))
                    .accessibilityIdentifier("processingStatus").accessibilityLabel(model.statusText)
                ProgressView(value:min(1,max(0,model.phase.progress))).tint(.acAccent)
                DesktopFact(title:"完成进度",value:processingPercent)
                Text(isPaused ? "可以继续处理，或返回调整参数。" : "保持实时跟踪，完成后进入成片预览。")
                    .font(.system(size:12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing:4) {
                    ForEach(WorkspaceTool.allCases,id:\.self) {tool in
                        let selected=(activeTool ?? .selection)==tool
                        Button {selectTool(tool)} label: {
                            Label(tool.rawValue,systemImage:tool.symbol).font(.system(size:12,weight:.medium))
                                .frame(maxWidth:.infinity).frame(height:34)
                                .background(selected ? DesktopPalette.raised : .clear,in:RoundedRectangle(cornerRadius:7))
                        }.buttonStyle(.plain).foregroundStyle(selected ? .white : .secondary)
                            .accessibilityIdentifier("tool-"+tool.rawValue).accessibilityAddTraits(selected ? .isSelected : [])
                            .disabled(!model.settingsEnabled || timelineTrimming || model.compositionBusy || model.compositionAdjusting || (tool != .selection && model.project?.target == nil))
                    }
                }.padding(4).background(DesktopPalette.background,in:RoundedRectangle(cornerRadius:10))
                    .accessibilityElement(children:.contain).accessibilityIdentifier("editorToolbar")
                if let activity=model.editorActivityText {
                    HStack(spacing:8) {
                        ProgressView().controlSize(.small)
                        Text(activity).font(.system(size:11)).foregroundStyle(.secondary)
                    }.accessibilityElement(children:.combine).accessibilityIdentifier("editorActivity")
                }
                if activeTool == .composition {desktopCompositionSettings}
                else if activeTool == .redaction {desktopRedactionSettings}
                else {
                    DesktopSection(title:"主角选择") {
                        Image(systemName:model.project?.target == nil ? "person.crop.rectangle.badge.plus" : "person.crop.rectangle.fill")
                            .font(.system(size:28)).foregroundStyle(Color.acAccent).padding(.vertical,6)
                        Text(model.project?.target == nil ? "点击画面中的主角" : "主角已选中")
                            .font(.system(size:16,weight:.semibold))
                        Text("在完整原片中点击人物即可切换。镜头会跟随主角，其他人物可在打码中自动遮挡。")
                            .font(.system(size:12)).foregroundStyle(.secondary).lineSpacing(5)
                        Button(action:beginManual) {Label("手动框选",systemImage:"viewfinder")}
                            .buttonStyle(DesktopButtonStyle()).accessibilityLabel("手动框选人物")
                    }
                }
            }
            Spacer(minLength:0)
            Divider()
            DesktopSection(title:"当前视频") {
                DesktopFact(title:"输出比例",value:model.project?.settings.aspectRatio.rawValue ?? "16:9")
                DesktopFact(title:"输出尺寸",value:model.project?.settings.resolution.label ?? "")
                DesktopFact(title:"片段时长",value:((model.project?.settings.end ?? 0)-(model.project?.settings.start ?? 0)).videoTime)
            }
        }.padding(20).frame(maxHeight:.infinity,alignment:.top)
    }
    private var desktopCompositionSettings:some View {
        VStack(alignment:.leading,spacing:18) {
            DesktopSection(title:"画面比例") {
                Picker("画面比例",selection:Binding(get:{model.project?.settings.aspectRatio ?? .portrait},set:{value in
                    withAnimation(reduceMotion ? nil : .smooth(duration:0.32)) {model.setCompositionAspect(value)}
                })) {ForEach(OutputAspectRatio.allCases) {Text($0.rawValue).tag($0)}}
                    .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("compositionAspect")
            }.disabled(compositionControlsDisabled)
            DesktopSection(title:"位置与缩放") {
                HStack(spacing:8) {
                    Button {model.compositionZoom(1/1.1)} label:{Label("缩小",systemImage:"minus.magnifyingglass").frame(maxWidth:.infinity)}
                    Button {model.compositionZoom(1.1)} label:{Label("放大",systemImage:"plus.magnifyingglass").frame(maxWidth:.infinity)}
                }.buttonStyle(DesktopButtonStyle())
                HStack(spacing:8) {
                    Button {model.centerComposition(horizontal:true)} label:{Label("水平居中",systemImage:"align.horizontal.center").frame(maxWidth:.infinity)}
                    Button {model.centerComposition(horizontal:false)} label:{Label("垂直居中",systemImage:"align.vertical.center").frame(maxWidth:.infinity)}
                }.buttonStyle(DesktopButtonStyle())
                Text(model.editorActivityText ?? model.compositionNotice ?? "直接拖动画面调整位置，双指缩放。")
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }.disabled(compositionControlsDisabled)
            HStack {toolCancel;Spacer();toolCommit}
        }
            .accessibilityElement(children:.contain).accessibilityIdentifier("adjustmentPanel")
    }
    private var desktopRedactionSettings:some View {
        VStack(alignment:.leading,spacing:18) {
            Toggle("遮挡其他人物",isOn:Binding(get:{model.project?.settings.redaction.enabled == true},set:{if $0 {model.enableAutomaticRedaction()} else {model.clearRedactions()}}))
                .font(.system(size:13)).tint(.acAccent)
            DesktopSection(title:"遮挡范围") {
                Picker("遮挡范围",selection:Binding(get:{model.project?.settings.redaction.region ?? .face},set:{model.setRedactionRegion($0)})) {
                    ForEach(RedactionSettings.Region.allCases,id:\.self) {Text($0.rawValue).tag($0)}
                }.pickerStyle(.segmented).labelsHidden()
            }
            DesktopSection(title:"遮挡样式") {
                HStack(spacing:6) {
                    ForEach(RedactionSettings.Style.allCases,id:\.self) {style in
                        Button {
                            if style == .image && model.project?.settings.redaction.imageData == nil {showRedactionImagePicker=true}
                            else {model.setRedactionStyle(style)}
                        } label: {
                            Text(style.rawValue).font(.system(size:12)).frame(maxWidth:.infinity).frame(height:34)
                                .foregroundStyle(model.project?.settings.redaction.style == style ? Color.acOnAccent : .white)
                                .background(model.project?.settings.redaction.style == style ? Color.acAccent : DesktopPalette.raised,in:RoundedRectangle(cornerRadius:7))
                        }.buttonStyle(.plain).accessibilityIdentifier("redaction-style-"+style.rawValue)
                    }
                }
                if model.project?.settings.redaction.style == .image {
                    Button("更换图片") {showRedactionImagePicker=true}.buttonStyle(DesktopButtonStyle())
                } else {
                    Slider(value:Binding(get:{model.project?.settings.redaction.strength ?? 0.65},set:{model.setRedactionStrength($0)}),in:0.3...1)
                        .tint(.acAccent).accessibilityLabel("打码强度")
                }
            }
            Text("主角保持清晰，其余人物自动遮挡。") .font(.system(size:11)).foregroundStyle(.secondary)
            HStack {toolCancel;Spacer();toolCommit}
        }.accessibilityElement(children:.contain).accessibilityIdentifier("adjustmentPanel")
    }
    #endif
    private var header: some View {
        HStack {
            StudioIcon(symbol: "chevron.left", label: "返回项目首页") { showLeaveConfirmation = true }
            Spacer()
            Group {
                if isBlocked {
                    Text("需要确认人物").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7).background(Color.acAccent, in: Capsule()).foregroundStyle(.black)
                        .accessibilityIdentifier("processingStatus").accessibilityLabel(model.statusText).accessibilityValue(model.currentTime.videoTime)
                } else if isProcessing {
                    Text("视频编辑").font(.system(size:15,weight:.medium))
                        .accessibilityIdentifier("processingStatus").accessibilityLabel(model.statusText).accessibilityValue(model.currentTime.videoTime)
                } else {
                    Text(activeTool?.rawValue ?? "选择舞者").font(.system(size: 15, weight: .medium))
                }
            }
            Spacer()
            // Preserve header symmetry and expose source metadata without permanent screen clutter.
            Color.clear.frame(width: 44, height: 44).accessibilityElement()
                .accessibilityLabel("输出比例" + (model.project?.settings.aspectRatio.rawValue ?? "16:9")).accessibilityIdentifier("sourceVideoMetadata")
                .accessibilityValue("原片 \(Int(model.project?.metadata.width ?? 0)) × \(Int(model.project?.metadata.height ?? 0))")
        }.padding(.horizontal, 18).frame(height: 52)
    }
    private var showsComposition: Bool { model.compositionEditing && !timelineTrimming && model.compositionCrop != nil }
    private var sourceStage: some View {
        GeometryReader { geometry in
            let source = model.project?.metadata.size ?? CGSize(width: 1920, height: 1080)
            let inset:CGFloat=showsComposition ? 16 : 12
            let area=CGSize(width:max(1,geometry.size.width-inset*2),height:max(1,geometry.size.height-(showsComposition ? 12 : 48)))
            let rect=CropGeometry.aspectFit(video:showsComposition ? (model.project?.settings.aspectRatio ?? .portrait).size : source,container:area).offsetBy(dx:inset,dy:0)
            ZStack(alignment: .bottom) {
                CompositionVideoViewport(model:model,source:source,viewport:rect.size,composition:showsComposition)
                    .frame(width:rect.width,height:rect.height)
                    .accessibilityElement(children:showsComposition ? .contain : .ignore)
                    .accessibilityLabel(showsComposition ? "构图预览" : "原片画面")
                    .accessibilityIdentifier(showsComposition ? "compositionViewport" : "sourceVideoSurface")
                    .position(x:rect.midX,y:rect.midY)
                if !model.redactionEditing && !model.compositionEditing && model.controlsEnabled && !model.manualSelection && !model.isPlaying && !timelineTrimming {
                    ForEach(people, id: \.id) { person in
                        let number = person.number, box = person.box
                        Button { model.selectTarget(box) } label: {
                            CandidateCorners()
                                .stroke(model.redactionEditing && model.redactionSelected(box) ? Color.acAccent : .white.opacity(0.85), style: StrokeStyle(lineWidth:model.redactionEditing && model.redactionSelected(box) ? 2.5 : 1.5,lineCap:.round))
                                .opacity(activeBox.map {$0.iou(box)>0.8} == true ? 0 : 1)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .frame(width: rect.width * box.width, height: rect.height * box.height)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                            .position(x: rect.minX + rect.width * box.center.x, y: rect.minY + rect.height * box.center.y)
                            .disabled((model.redactionEditing || model.redactionIssue != nil) && !model.canRedactPerson(box))
                            .accessibilityLabel(model.redactionEditing && !model.canRedactPerson(box) ? "主角，不参与打码" : model.redactionEditing ? (model.redactionSelected(box) ? "移除打码人物 \(number+1)" : "打码人物 \(number+1)") : (model.isDemo ? "选择舞者 \(number + 1)" : "选择人物 \(number + 1)"))
                            .accessibilityIdentifier(model.isDemo ? "dancer\(number)" : "person\(number)")
                    }
                }
                if let box = activeBox, !showsComposition && !model.manualSelection && !model.isPlaying {
                    TargetBox(label: boxLabel, status: boxLabel, warning: isBlocked && model.redactionIssue == nil, dashed: isProcessing && model.trackedSample?.estimated == true, badgeInside: rect.minY + rect.height * box.y < 34)
                        .frame(width: rect.width * box.width, height: rect.height * box.height)
                        .position(x: rect.minX + rect.width * box.center.x, y: rect.minY + rect.height * box.center.y)
                        .allowsHitTesting(false)
                }
                if model.manualSelection {
                    ManualBoxOverlay(box: $drawnBox).frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                if !isProcessing && !model.compositionEditing {
                    HStack(spacing: 8) {
                        if model.detecting || model.restoringTracking { ProgressView().tint(.white) }
                        Text(sourceHint).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                    }.padding(.horizontal, 20).frame(height: 44).allowsHitTesting(false)
                }
            }
        }.animation(reduceMotion ? nil : .smooth(duration:0.32),value:showsComposition)
            .animation(reduceMotion ? nil : .smooth(duration:0.32),value:model.project?.settings.aspectRatio)
    }
    private var sourceHint: String {
        if model.manualSelection { return "拖动框体移动 · 拖四角调整" }
        if let activity=model.editorActivityText {return activity}
        if model.phase == .editing,model.hasCompletedTracking,let project=model.project,
           project.settings.redaction.enabled,project.redactionPlan?.covers(project) != true {
            return "打码已更改 · 重新生成后可播放"
        }
        if model.redactionIssue != nil {return "轻点需要继续打码的同一人物"}
        if model.redactionEditing {return model.project?.settings.redaction.enabled == true ? "自动遮挡所有其他人物 · 主角保持清晰" : "打码已关闭"}
        if isBlocked { return "轻点原片中的目标舞者" }
        if model.detecting { return "正在识别人物" }
        if let notice = model.detectionNotice { return notice }
        return "轻点人物进行选择"
    }
    @ViewBuilder private var recoveryDock: some View {
        if model.manualSelection {
            VStack(spacing: 12) {
                Spacer()
                HStack {
                    Button("取消") { model.manualSelection = false; drawnBox = nil }.frame(minWidth: 64, minHeight: 44)
                    Spacer()
                    Button("重画") { drawnBox = nil }.frame(minWidth: 64, minHeight: 44)
                }
                StudioAction(title: "确认区域并识别", disabled: drawnBox == nil || model.detecting) {
                    guard let box = drawnBox else { return }
                    model.finishManualBox(box); model.manualSelection = false; drawnBox = nil
                }
                Spacer().frame(height: 10)
            }.padding(.horizontal, 24)
        } else if isBlocked {
            VStack(spacing: 10) {
                Spacer()
                HStack(spacing: 24) {
                    StudioIcon(symbol: "backward.end.fill", label: "查看前一帧") { model.seek(to: model.currentTime - 0.2) }
                    Button("手动框选") { beginManual() }.font(.system(size: 13))
                        .padding(.horizontal, 24).frame(height: 44).modifier(StudioGlassSurface(shape: Capsule()))
                        .accessibilityLabel("手动框选人物")
                    StudioIcon(symbol: "forward.end.fill", label: "查看后一帧") { model.seek(to: model.currentTime + 0.2) }
                }
                StudioAction(title: "确认并继续", disabled: !model.canConfirm) { model.confirmProcessing() }
                Spacer().frame(height: 10)
            }.frame(maxWidth: .infinity)
        }
    }

    private var playbackRow: some View {
        HStack {
            Text(model.currentTime.videoTime).foregroundStyle(.white)
                + Text(" / " + (model.project?.metadata.duration ?? 0).videoTime).foregroundStyle(.white.opacity(0.45))
            Spacer()
            Button { model.togglePreview() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22)).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(model.isPlaying ? "暂停预览" : "播放预览")
                .accessibilityIdentifier("editorPlayback").keyboardShortcut(.space,modifiers:[])
                .disabled(isProcessing || timelineTrimming || (model.project?.settings.redaction.enabled == true && model.project?.redactionPlan?.covers(model.project!) != true) || model.compositionEditing && !model.hasCompletedTracking || model.compositionBusy)
            Spacer()
            Text(model.project?.settings.aspectRatio.rawValue ?? "16:9").foregroundStyle(.white.opacity(0.45)).frame(width: 60, alignment: .trailing)
        }.font(.system(.caption, design: .monospaced)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 26).frame(height: 44)
    }

    private var bottomToolbar: some View {
        StudioGlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                if !isProcessing {
                    HStack(spacing: 0) {
                        ForEach(WorkspaceTool.allCases, id: \.self) { tool in
                            let selected = (activeTool ?? .selection) == tool
                            Button { selectTool(tool) } label: {
                                VStack(spacing: 3) {
                                    Image(systemName: tool.symbol).symbolRenderingMode(.monochrome)
                                        .font(.system(size: 20, weight: .regular))
                                    Text(tool.rawValue).font(.caption2.weight(selected ? .semibold : .regular))
                                        .lineLimit(1).minimumScaleFactor(0.6)
                                }.frame(maxWidth: .infinity).frame(height: 50)
                                    .foregroundStyle(.white.opacity(selected ? 1 : 0.65))
                                    .modifier(StudioGlassSelection(selected:selected,namespace:toolSelection,selectionID:"selected-tool",optionID:tool.rawValue))
                                    .contentShape(Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("tool-" + tool.rawValue)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .disabled(!model.settingsEnabled || timelineTrimming || model.compositionBusy || model.compositionAdjusting || ((tool == .composition || tool == .redaction) && model.project?.target == nil))
                        }
                    }.padding(4).modifier(StudioGlassSurface(shape: Capsule()))
                        .accessibilityElement(children: .contain).accessibilityIdentifier("editorToolbar")
                            .transition(.opacity.combined(with:.move(edge:.leading)))
                }
                if isPaused {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth(duration:0.28)) {
                            activeTool=nil;model.returnToEditingFromPause()
                        }
                    } label: {
                        Label("返回调整",systemImage:"slider.horizontal.3")
                            .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                            .frame(width:116,height:56).contentShape(Capsule())
                    }.buttonStyle(.plain)
                        .modifier(StudioGlassSurface(shape:Capsule()))
                        .accessibilityIdentifier("returnToEditingFromPause")
                        .transition(.opacity.combined(with:.move(edge:.leading)))
                }
                processingAction
            }
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, 18).frame(height: 58)
    }
    private var processingAction:some View {
                Button {
                    if isProcessing {
                        if isPaused { model.resume() } else { model.pause() }
                    } else {
                        withAnimation(reduceMotion ? nil : .smooth(duration:0.28)) {
                            finishTool(commit:true);model.confirmProcessing()
                        }
                    }
                } label: {
                    HStack(spacing:8) {
                        Text(isProcessing ? (isPaused ? "已暂停" : "处理中") : startTitle)
                            .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.5)
                        if isProcessing {
                            Image(systemName:isPaused ? "play.fill" : "pause.fill").font(.system(size:12))
                            Spacer(minLength:12)
                            Text(processingPercent).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .contentTransition(.numericText()).accessibilityIdentifier("processingProgress")
                        } else {
                            Image(systemName:"arrow.right").font(.system(size:16,weight:.medium))
                        }
                    }.padding(.horizontal,isProcessing ? 22 : 14)
                        .frame(maxWidth:isProcessing || usesExpandedWorkspace ? .infinity : nil).frame(width:isProcessing || usesExpandedWorkspace ? nil : 132,height:56)
                        .background {
                            if isProcessing {
                                ProcessingButtonFill(progress:min(1,max(0,model.phase.progress)),paused:isPaused)
                            }
                        }
                        .contentShape(Capsule())
                        .foregroundStyle(.white.opacity(isProcessing || canStart ? 1 : 0.3))
                }.buttonStyle(.plain).contentShape(Capsule())
                    .modifier(StudioGlassSurface(shape:Capsule(),selected:isProcessing || canStart))
                    .disabled(!isProcessing && !canStart)
                    .accessibilityLabel(isProcessing ? (isPaused ? "已暂停，继续处理" : "处理中，暂停处理") : startTitle)
                    .accessibilityValue(isProcessing ? processingPercent : "")
                    .accessibilityHint(isProcessing ? (isPaused ? "点按继续处理" : "点按暂停处理") : "按当前舞者、时间范围和构图生成视频")
                    .accessibilityIdentifier("primaryAction")
    }
    private var usesExpandedWorkspace:Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        horizontalSizeClass == .regular
        #endif
    }
    private var editorTimeline:some View {
        VStack(spacing:0) {
            playbackRow
            TrimTimeline(model:model,onEditingChanged:{timelineTrimming=$0})
                .coordinateSpace(.named("timeline")).padding(.horizontal,18)
                .disabled(isProcessing || isBlocked).allowsHitTesting(!isProcessing && !isBlocked)
        }
    }
    private var expandedControls:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Image(systemName:isProcessing ? "viewfinder" : activeTool?.symbol ?? "person.crop.circle")
                    .foregroundStyle(Color.acAccent)
                Text(isBlocked ? "确认主角" : isProcessing ? (isPaused ? "处理已暂停" : "正在跟随主角") : activeTool?.rawValue ?? "主角选择")
                    .font(.headline)
                Spacer(minLength:0)
            }.padding(.horizontal,18).padding(.top,20)
            if isBlocked || model.manualSelection {
                recoveryDock.frame(height:180)
            } else if isProcessing {
                VStack(alignment:.leading,spacing:12) {
                    ProgressView(value:min(1,max(0,model.phase.progress))).tint(.acAccent)
                    Text(isPaused ? "继续处理，或返回调整构图与打码。" : "完成后将自动进入成片预览。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.horizontal,18)
            } else if let tool=activeTool {
                inlineSettings(tool).frame(height:tool == .composition ? 184 : tool == .redaction ? 164 : 104)
            } else {
                VStack(alignment:.leading,spacing:12) {
                    Text(model.project?.target == nil ? "在原片中轻点主角" : "主角已选中")
                        .font(.title3.weight(.semibold))
                    Text("直接点击人物切换主角。拖动时间轴两端截取，再调整构图和其他人物的遮挡。")
                        .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                    Button("手动框选",action:beginManual).font(.subheadline).frame(minHeight:44)
                        .accessibilityLabel("手动框选人物")
                }.padding(.horizontal,18)
            }
            Spacer(minLength:0)
            if !isBlocked && !model.manualSelection {
                VStack(spacing:12) {
                    if !isProcessing {
                        HStack(spacing:4) {
                            ForEach(WorkspaceTool.allCases,id:\.self) {tool in
                                let selected=(activeTool ?? .selection)==tool
                                Button {selectTool(tool)} label: {
                                    Label(tool.rawValue,systemImage:tool.symbol)
                                        .font(.system(size:14,weight:.medium)).labelStyle(.titleAndIcon)
                                        .frame(maxWidth:.infinity).frame(height:48)
                                        .modifier(StudioGlassSelection(selected:selected,namespace:toolSelection,selectionID:"expanded-tool",optionID:tool.rawValue))
                                }.buttonStyle(.plain).accessibilityIdentifier("tool-"+tool.rawValue)
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .disabled(!model.settingsEnabled || timelineTrimming || model.compositionBusy || model.compositionAdjusting || (tool != .selection && model.project?.target == nil))
                            }
                        }.padding(4).modifier(StudioGlassSurface(shape:Capsule()))
                            .accessibilityElement(children:.contain).accessibilityIdentifier("editorToolbar")
                    }
                    if isPaused {
                        Button {activeTool=nil;model.returnToEditingFromPause()} label: {
                            Label("返回调整",systemImage:"slider.horizontal.3").font(.subheadline)
                                .frame(maxWidth:.infinity,minHeight:44)
                        }.buttonStyle(.plain).accessibilityIdentifier("returnToEditingFromPause")
                    }
                    processingAction
                }.padding(.horizontal,14).padding(.bottom,14)
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:28))
            .overlay {RoundedRectangle(cornerRadius:28).stroke(.white.opacity(0.08),lineWidth:0.5).allowsHitTesting(false)}
    }
    private var processingPercent:String {
        min(1,max(0,model.phase.progress)).formatted(.percent.precision(.fractionLength(0)))
    }
    private var canStart: Bool { !timelineTrimming && model.canConfirm }
    private var startTitle: String {
        if model.restoringTracking {return "正在恢复项目…"}
        if model.compositionBusy {return "正在准备预览…"}
        if model.importingRedactionImage {return "正在准备图片…"}
        if model.detecting {return "正在识别人物…"}
        if model.isPlaying {return "请先暂停预览"}
        if model.needsRegeneration {return "重新生成"}
        if activeTool == .composition { return "确认并处理" }
        return model.hasReusableOutput ? "预览成片" : "开始处理"
    }

    private func selectTool(_ tool: WorkspaceTool) {
        guard !model.compositionBusy, !model.compositionAdjusting else { return }
        let wasSelected = activeTool == tool
        finishTool(commit: true)
        guard !wasSelected else { return }
        model.pausePreview(refresh: false)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            if tool == .composition { model.beginComposition(); guard model.compositionEditing else { return } }
            if tool == .redaction {redactionStrengthEditing=false;model.beginRedaction()}
            activeTool = tool
        }
    }
    private func finishTool(commit: Bool) {
        guard let tool = activeTool else { return }
        if commit && (model.compositionBusy || model.compositionAdjusting) { return }
        switch tool {
        case .composition: model.finishComposition(commit: commit)
        case .redaction: model.finishRedaction(commit:commit)
        case .selection: break
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { activeTool = nil }
    }
    private func beginManual() {
        guard model.controlsEnabled else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            finishTool(commit: true)
            model.beginManualSelection()
            drawnBox = model.project?.target ?? .init(x: 0.32, y: 0.12, width: 0.36, height: 0.76)
        }
    }

    @ViewBuilder private func inlineSettings(_ tool: WorkspaceTool) -> some View {
        Group {
            if tool == .composition {
                compositionPanel
            } else if tool == .redaction {
                redactionPanel
            } else {
                VStack(spacing: 8) {
                    HStack {
                        toolCancel
                        Spacer()
                        Text("直接轻点画面中的舞者").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        toolCommit
                    }
                    Button("手动框选", action: beginManual).font(.subheadline)
                        .frame(minHeight: 44).accessibilityLabel("手动框选人物")
                }
            }
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, 18)
            .accessibilityElement(children: .contain).accessibilityIdentifier("adjustmentPanel")
    }
    private var redactionPanel: some View {
        VStack(spacing:0) {
            if redactionStrengthEditing && model.project?.settings.redaction.style != .image {
                HStack(spacing:12) {
                    Text("强度").font(.caption)
                    Slider(value:Binding(get:{model.project?.settings.redaction.strength ?? 0.65},set:{model.setRedactionStrength($0)}),in:0.3...1)
                        .tint(.white).accessibilityLabel("打码强度").accessibilityIdentifier("redactionStrength")
                }.frame(height:50)
            } else {
            StudioGlassGroup(spacing:4) {
                HStack(spacing:4) {
                    ForEach(RedactionSettings.Region.allCases,id:\.self) { region in
                        let selected=model.project?.settings.redaction.region == region
                        Button {withAnimation(reduceMotion ? nil : .smooth(duration:0.25)) {model.setRedactionRegion(region)}} label: {
                            Text(region.rawValue).font(.subheadline.weight(selected ? .semibold : .regular))
                                .frame(maxWidth:.infinity).frame(height:44)
                                .modifier(StudioGlassSelection(selected:selected,namespace:redactionSelection,selectionID:"redaction-region",optionID:region.rawValue))
                        }.buttonStyle(.plain).accessibilityIdentifier("redaction-"+region.rawValue)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(3).background(.black.opacity(0.14),in:Capsule())
            }
            }
            StudioGlassGroup(spacing:4) {
                HStack(spacing:4) {
                    ForEach(RedactionSettings.Style.allCases,id:\.self) { style in
                        let selected=model.project?.settings.redaction.style == style
                        Button {
                            if style == .image && (selected || model.project?.settings.redaction.imageData == nil) {showRedactionImagePicker=true}
                            else {withAnimation(reduceMotion ? nil : .smooth(duration:0.25)) {model.setRedactionStyle(style)}}
                        } label: {
                            Text(style.rawValue).font(.caption.weight(selected ? .semibold : .regular))
                                .frame(maxWidth:.infinity).frame(height:44)
                                .modifier(StudioGlassSelection(selected:selected,namespace:redactionStyleSelection,selectionID:"redaction-style",optionID:style.rawValue))
                        }.buttonStyle(.plain).accessibilityIdentifier("redaction-style-"+style.rawValue)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(3).background(.black.opacity(0.14),in:Capsule())
            }
            HStack(spacing:8) {
                toolCancel
                Spacer(minLength:0)
                if model.importingRedactionImage {ProgressView().frame(width:44,height:44)}
                else if model.redactionPrimaryBody == nil {
                    Button("预览遮挡") {model.seek(to:model.project?.targetTime ?? 0)}.font(.caption).frame(minWidth:64,minHeight:44)
                } else if model.project?.settings.redaction.style == .image {
                    Button("更换图片") {showRedactionImagePicker=true}.font(.caption).frame(minWidth:64,minHeight:44)
                } else {
                    Button(redactionStrengthEditing ? "范围" : "强度") {redactionStrengthEditing.toggle()}
                        .font(.caption).frame(minWidth:44,minHeight:44).accessibilityLabel("打码强度设置")
                }
                Button(model.project?.settings.redaction.enabled == true ? "关闭打码" : "开启打码") {
                    if model.project?.settings.redaction.enabled == true {model.clearRedactions()} else {model.enableAutomaticRedaction()}
                }.font(.caption).frame(minWidth:64,minHeight:44)
                Spacer(minLength:0)
                toolCommit
            }
        }.padding(.horizontal,12).padding(.vertical,8)
            .modifier(StudioGlassSurface(shape:RoundedRectangle(cornerRadius:24)))
    }
    private var compositionPanel: some View {
        VStack(spacing: 6) {
            StudioGlassGroup(spacing:4) {
                HStack(spacing: 4) {
                    ForEach(OutputAspectRatio.allCases) { aspect in
                        let selected = model.project?.settings.aspectRatio == aspect
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration:0.32)) { model.setCompositionAspect(aspect) }
                        } label: {
                            Text(aspect.rawValue).font(.system(.subheadline, design: .rounded).weight(selected ? .semibold : .regular))
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                                .modifier(StudioGlassSelection(selected:selected,namespace:aspectSelection,selectionID:"selected-aspect",optionID:aspect.rawValue))
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityLabel(aspect.rawValue)
                            .accessibilityIdentifier("aspect-" + aspect.rawValue)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(3).background(.black.opacity(0.14), in: Capsule())
                    .accessibilityElement(children: .contain).accessibilityLabel("画面比例")
                    .accessibilityIdentifier("compositionAspect")
                    .disabled(compositionControlsDisabled)
            }
            HStack(spacing: 0) {
                compositionControl("缩小", symbol: "minus.magnifyingglass") { model.compositionZoom(1 / 1.1) }
                compositionControl("放大", symbol: "plus.magnifyingglass") { model.compositionZoom(1.1) }
                Rectangle().fill(.white.opacity(0.12)).frame(width: 0.5, height: 28).padding(.horizontal, 4)
                compositionControl("水平居中", symbol: "align.horizontal.center") { model.centerComposition(horizontal: true) }
                compositionControl("垂直居中", symbol: "align.vertical.center") { model.centerComposition(horizontal: false) }
            }.disabled(compositionControlsDisabled)
            HStack(spacing: 8) {
                toolCancel
                Spacer(minLength: 0)
                Text(model.editorActivityText ?? model.compositionNotice ?? "拖动位置 · 双指缩放")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                toolCommit
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
            .modifier(StudioGlassSurface(shape: RoundedRectangle(cornerRadius: 24)))
    }
    private var compositionControlsDisabled: Bool { timelineTrimming || model.compositionBusy || model.compositionAdjusting }
    private var toolCancel: some View {
        Button { finishTool(commit: false) } label: {
            Text("取消").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
            .buttonStyle(.plain).accessibilityLabel("取消调整").accessibilityIdentifier("cancelTool").disabled(timelineTrimming)
    }
    private var toolCommit: some View {
        Button { finishTool(commit: true) } label: {
            Text("完成").font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
            .buttonStyle(.plain).accessibilityLabel("确定调整").accessibilityIdentifier("commitTool").disabled(compositionControlsDisabled || model.importingRedactionImage)
    }
    private func compositionControl(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).symbolRenderingMode(.monochrome).font(.system(size: 20))
                    .frame(height: 26)
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.65)
            }.frame(maxWidth: .infinity).frame(height: 56).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("构图" + title)
    }
    private var activeBox: NormalizedRect? {
        if model.redactionEditing || model.redactionIssue != nil {return model.redactionPrimaryBody}
        if isBlocked && !model.targetExplicitlySelected { return nil }

        if model.isDemo, isProcessing, let target = model.project?.target {
            let index = max(0, min(3, Int(((target.center.x * 360 - 57) / 82).rounded())))
            return DemoStage.body(index: index, time: model.currentTime)
        }
        if !model.isDemo, isProcessing {
            return model.trackedSample?.body ?? model.project.flatMap {RedactionPolicy.primaryBody(project:$0,time:model.currentTime,samples:model.targetSamples)}
        }
        if let project = model.project, abs(model.currentTime - project.targetTime) > 0.05 { return nil }
        return model.project?.target
    }
    private var isPaused: Bool { if case .paused = model.phase { return true }; return false }
    private var boxLabel: String { "主角" }
}

struct TargetBox:View {
    let label:String
    let status:String
    var warning:Bool
    var dashed:Bool
    var badgeInside = false
    private var tint:Color { warning ? .orange : .acAccent }
    var body:some View {
        GeometryReader { geometry in
            let radius=min(8,max(2,geometry.size.width*0.12))
            RoundedRectangle(cornerRadius:radius)
                .stroke(tint,style:StrokeStyle(lineWidth:2,lineCap:.round,dash:dashed ? [4,3] : []))
                .overlay(alignment:.top) {
                    Text(status)
                        .font(.system(size:11,weight:.medium))
                        .lineLimit(1).fixedSize(horizontal:true,vertical:false)
                        .padding(.horizontal,12).frame(height:26)
                        .foregroundStyle(Color.acOnAccent)
                        .background(tint,in:RoundedRectangle(cornerRadius:7))
                        .fixedSize(horizontal:true,vertical:false)
                        .offset(y: badgeInside ? 8 : -34)
                }
        }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel(label)
        .accessibilityValue(dashed ? "预测位置" : (warning ? "等待确认" : "检测位置"))
        .accessibilityIdentifier("selectedTargetFrame")
    }
}

/// A determinate fill inside the existing button; it never changes the button's layout or hit area.
private struct ProcessingButtonFill: View {
    let progress: Double
    let paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(LinearGradient(colors:[Color.acAccent.opacity(0.30),Color.acAccent.opacity(0.16)],startPoint:.leading,endPoint:.trailing))
                .overlay(alignment:.trailing) {
                    Rectangle().fill(Color.acAccent.opacity(0.55)).frame(width:1)
                }
                .frame(width:geometry.size.width*progress,height:geometry.size.height)
                .animation(reduceMotion || paused ? nil : .linear(duration:0.15),value:progress)
        }.clipShape(Capsule()).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Quiet corner marks reveal tappable candidates without enclosing each dancer in a heavy border.
private struct CandidateCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length=min(12,min(rect.width,rect.height)*0.25)
        return Path { path in
            for (x,y,dx,dy) in [(rect.minX,rect.minY,1.0,1.0),(rect.maxX,rect.minY,-1.0,1.0),(rect.minX,rect.maxY,1.0,-1.0),(rect.maxX,rect.maxY,-1.0,-1.0)] {
                path.move(to:.init(x:x+dx*length,y:y))
                path.addLine(to:.init(x:x,y:y))
                path.addLine(to:.init(x:x,y:y+dy*length))
            }
        }
    }
}
