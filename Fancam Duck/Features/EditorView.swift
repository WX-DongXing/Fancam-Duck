import SwiftUI
import AVFoundation

struct EditorView: View {
    @Bindable var model: AppModel
    @State private var savingFile=false
    @State private var generatedPlaying=false
    @State private var showRedactionHelp=false
    @State private var drawnBox: NormalizedRect?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var settingsHeight = 154
    @State private var activeTool: WorkspaceTool?
    @State private var lastSettingsTool:WorkspaceTool = .composition
    @State private var timelineTrimming = false
    @State private var selectionZoom:CGFloat = 1
    @State private var selectionPan:CGSize = .zero
    @GestureState private var selectionPinch:CGFloat = 1
    @GestureState private var selectionDrag:CGSize = .zero

    private enum WorkspaceTool: String, CaseIterable {
        case composition = "构图", motion = "运镜", redaction = "打码"
        var symbol: String {
            switch self {
            case .composition: "crop"
            case .motion: "video"
            case .redaction: "square.on.circle"
            }
        }
    }

    private var workspaceState:String {
        if isBlocked {return "blocked"}
        if isCompleted {return "preview"}
        if model.generatingVideo {return "generating"}
        if isPaused {return "paused"}
        if isProcessing {return "analyzing"}
        return model.hasCompletedTracking ? "settings" : "selection"
    }
    private var isCompleted:Bool {if case .completed = model.phase {return true};return false}
    private var availableTools:[WorkspaceTool] {model.hasCompletedTracking ? [.composition,.motion,.redaction] : []}
    private var isProcessing: Bool {
        switch model.phase { case .processing, .paused: true; default: false }
    }
    private var isBlocked: Bool { model.phase.issue != nil }
    private var people: [(id: Int, number: Int, box: NormalizedRect)] {
        if model.isDemo {
            #if DEBUG
            if ProcessInfo.processInfo.environment["FANCAM_DUCK_UI_OVERLAP"] == "1" {
                return [(1,1,NormalizedRect(x:0.1,y:0.1,width:0.5,height:0.8)),
                        (2,2,NormalizedRect(x:0.33,y:0.1,width:0.5,height:0.8))]
            }
            #endif
            return (0..<4).map { (id:$0,number:$0,box:DemoStage.body(index:$0,time:model.currentTime)) }
        }
        return model.observations.sorted { $0.body.center.x < $1.body.center.x }.enumerated().map { (id: $0.element.id, number: $0.offset, box: $0.element.body) }
    }
    var body: some View {
        GeometryReader { geometry in
            #if targetEnvironment(macCatalyst)
            desktopWorkspace
            #else
            VStack(spacing: 0) {
                header.zIndex(100)
                WorkspaceArrangement(size:CGSize(width:geometry.size.width,height:max(1,geometry.size.height-52))) {
                    VStack(spacing:0) {
                        sourceStage.accessibilityElement(children:.contain).accessibilityIdentifier("editorStage")
                        if usesExpandedWorkspace && ((!isBlocked && !model.manualSelection) || model.isReviewing) {editorTimeline.padding(.bottom,12)}
                    }
                } controls: {
                    if usesExpandedWorkspace {expandedControls}
                    else {
                        VStack(spacing:0) {
                            if isBlocked || model.manualSelection {
                                if model.isReviewing {editorTimeline}
                                recoveryDock.frame(height:model.manualSelection ? 244 : 180,alignment:.bottom)
                            } else {
                                editorTimeline
                                if let tool=displayedTool,!isProcessing {
                                    inlineSettings(tool)
                                        .frame(height:tool == .redaction ? min(184,geometry.size.height*0.30) : tool == .motion ? min(settingsHeight*104/154,140,geometry.size.height*0.30) : min(settingsHeight,208,geometry.size.height*0.38),alignment:.top)
                                        .clipped()
                                        .transition(.opacity)
                                }
                                bottomToolbar.padding(.top,12).padding(.bottom,8)
                            }
                        }
                    }
                }
                // Animate the common layout so the panel, timeline and video resize together.
                .animation(settingsPanelAnimation,value:displayedTool)
            }.frame(width: geometry.size.width, height: geometry.size.height)
            #endif
        }
        .animation(reduceMotion ? nil : .smooth(duration:0.28),value:workspaceState)
        .background { StudioBackground() }.foregroundStyle(.white).preferredColorScheme(.dark)
        .sheet(isPresented:$savingFile) {if let url=model.outputURL {SaveVideoPicker(url:url)}}
        .onChange(of:model.hasCompletedTracking) {_,complete in
            if complete && model.phase == .editing {selectTool(.composition)}
        }
        .onChange(of: model.phase) { _, phase in
            generatedPlaying=false
            if phase != .editing {
                withAnimation(reduceMotion ? nil : .smooth(duration:0.28)) { activeTool = nil }
            } else if model.hasCompletedTracking,activeTool == nil {selectTool(lastSettingsTool)}
        }
        .onChange(of: model.compositionEditing) { _, editing in
            if !editing && activeTool == .composition { activeTool = nil }
        }
        .onAppear {if model.hasCompletedTracking && model.phase == .editing {selectTool(.composition)}}
        .task(id:generatedPlaying) {
            while generatedPlaying && isCompleted && !Task.isCancelled {
                if let time=model.previewPlayer?.currentTime().seconds,time.isFinite,let project=model.project {
                    model.currentTime=min(project.settings.end,project.settings.start+max(0,time))
                }
                do {try await Task.sleep(for:.milliseconds(100))} catch {return}
            }
        }
        .onChange(of:scenePhase) {_,phase in
            if phase != .active {generatedPlaying=false;model.previewPlayer?.pause()}
        }
        .onReceive(NotificationCenter.default.publisher(for:.AVPlayerItemDidPlayToEndTime)) {notification in
            if let item=notification.object as? AVPlayerItem,item === model.previewPlayer?.currentItem {generatedPlaying=false}
        }
        .onChange(of:model.project?.id) {_,_ in resetSelectionZoom()}
        .onChange(of:showsComposition) {_,_ in resetSelectionZoom()}
        .onChange(of:isProcessing) {_,processing in if processing {resetSelectionZoom()}}
        .onChange(of:model.manualSelection) {_,manual in if manual {resetSelectionZoom()}}
        .onDisappear { model.player?.pause();model.previewPlayer?.pause() }
    }
    #if targetEnvironment(macCatalyst)
    private var desktopWorkspace:some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                Button {returnToHome()} label: {Label("项目",systemImage:"chevron.left")}
                    .buttonStyle(DesktopButtonStyle()).accessibilityLabel("返回项目首页")
                Rectangle().fill(DesktopPalette.border).frame(width:1,height:24)
                VStack(alignment:.leading,spacing:3) {
                    Text(model.project?.title ?? "视频编辑").font(.system(size:14,weight:.semibold)).lineLimit(1)
                    Text(model.hasCompletedTracking ? "FANCAM DUCK  /  预览设置" : "FANCAM DUCK  /  人物分析").font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength:8)

            }.padding(.horizontal,20).frame(height:64).background(DesktopPalette.panel).zIndex(100)
            Divider()
            HStack(spacing:0) {
                VStack(spacing:0) {
                    HStack {
                        Label(isCompleted ? "成片预览" : showsComposition ? "构图预览" : "原片全览",systemImage:isCompleted ? "play.rectangle" : showsComposition ? "crop" : "viewfinder")
                        Spacer()
                        Text("\(Int(model.project?.metadata.width ?? 0)) × \(Int(model.project?.metadata.height ?? 0))")
                            .monospacedDigit()
                    }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,20).frame(height:38)
                    sourceStage.padding(.horizontal,8)
                        .accessibilityElement(children:.contain).accessibilityIdentifier("editorStage")
                    Divider()
                    if (!isBlocked && !model.manualSelection) || model.isReviewing {
                        editorTimeline.padding(.bottom,16).background(DesktopPalette.panel)
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                desktopInspector.frame(width:360).background(DesktopPalette.panel)
                    .animation(settingsPanelAnimation,value:displayedTool)
            }
        }.background(DesktopPalette.background)
            .accessibilityElement(children:.contain).accessibilityIdentifier("desktopWorkspace")
    }
    private var desktopInspector:some View {
        VStack(alignment:.leading,spacing:18) {
            if isBlocked || model.manualSelection {
                Text("确认主角 · \(model.currentTime.videoTime)").font(.headline)
            } else if isCompleted {
                Text("视频已生成").font(.headline)
                DesktopFact(title:"视频时长",value:((model.project?.settings.end ?? 0)-(model.project?.settings.start ?? 0)).videoTime)
                DesktopFact(title:"分辨率",value:model.project?.settings.resolution.label ?? "")
            } else if !isProcessing {
                if model.hasCompletedTracking {
                    if let tool=displayedTool {
                        settingsPanel(tool)
                            .fixedSize(horizontal:false,vertical:true)
                    }
                } else {Text(model.project?.target == nil ? "请在画面中选择主角" : "主角已选择").font(.subheadline)}
                if let activity=model.editorActivityText {
                    HStack(spacing:8) {ProgressView().controlSize(.small);Text(activity).font(.caption).foregroundStyle(.secondary)}
                }
            }
            Spacer(minLength:0)
            if isBlocked || model.manualSelection {recoveryDock.frame(height:model.manualSelection ? 244 : 180)}
            else if isCompleted {completedActions}
            else if isProcessing {
                HStack(spacing:10) {
                    Button(model.generatingVideo ? "取消生成" : "重新选择") {
                        if model.generatingVideo {model.cancelGeneration()} else {model.reselectAnalysisTarget()}
                    }.buttonStyle(DesktopButtonStyle(height:bottomControlHeight))
                        .accessibilityIdentifier("reselectAnalysis")
                    processingAction
                }
            } else {
                HStack(spacing:12) {
                    if model.hasCompletedTracking {toolSelector.frame(width:156)}
                    processingAction.frame(maxWidth:.infinity)
                }
            }
        }.padding(20).frame(maxHeight:.infinity,alignment:.top)
    }
    #endif
    private func returnToHome() {
        model.goHome()
    }
    private var header: some View {
        HStack {
            StudioIcon(symbol: "chevron.left", label: "返回项目首页") { returnToHome() }
            Spacer()
            Group {
                if isBlocked {
                    Text("确认人物 · \(model.currentTime.videoTime)").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7).background(Color.acAccent, in: Capsule()).foregroundStyle(.black)
                        .accessibilityIdentifier("processingStatus").accessibilityLabel(model.statusText).accessibilityValue(model.currentTime.videoTime)
                } else if isProcessing {
                    Text(model.phase.progress>=0.9 ? "补全片段" : "人物分析").font(.system(size:15,weight:.medium))
                        .accessibilityIdentifier("processingStatus").accessibilityLabel(model.statusText).accessibilityValue(model.currentTime.videoTime)
                } else {
                    Text(model.hasCompletedTracking || isCompleted ? "预览设置" : "人物分析").font(.system(size: 15, weight: .medium))
                }
            }
            Spacer()
            // Preserve header symmetry and expose source metadata without permanent screen clutter.
            Color.clear.frame(width: 44, height: 44).accessibilityElement()
                .accessibilityLabel("输出比例" + (model.project?.settings.aspectRatio.rawValue ?? "16:9")).accessibilityIdentifier("sourceVideoMetadata")
                .accessibilityValue("原片 \(Int(model.project?.metadata.width ?? 0)) × \(Int(model.project?.metadata.height ?? 0))")
        }.padding(.horizontal, 18).frame(height: 52)
    }
    private var showsComposition: Bool {
        (model.compositionEditing || model.hasCompletedTracking && !isBlocked)
            && model.compositionCrop != nil
    }
    private var overlappingPeople:[OverlapPerson] {
        let candidates=people.map {OverlapPerson(id:$0.id,number:$0.number,body:$0.box)}
        return OverlapSelection.candidates(candidates)
    }
    private var selectionZoomEnabled:Bool {
        !showsComposition && !isCompleted && !isProcessing && !model.manualSelection && !timelineTrimming
    }
    private func resetSelectionZoom() {selectionZoom=1;selectionPan = .zero}
    private func clampedSelectionPan(_ value:CGSize,rect:CGRect,scale:CGFloat)->CGSize {
        let x=rect.width*(scale-1)/2,y=rect.height*(scale-1)/2
        return CGSize(width:min(x,max(-x,value.width)),height:min(y,max(-y,value.height)))
    }
    private var sourceStage: some View {
        GeometryReader { geometry in
            let source = model.project?.metadata.size ?? CGSize(width: 1920, height: 1080)
            let overlapCandidates=selectionZoomEnabled && !model.isPlaying && !model.detecting ? overlappingPeople : []
            let showsOverlapThumbnails = !overlapCandidates.isEmpty
            let inset:CGFloat=showsComposition ? 16 : 12
            let area=CGSize(width:max(1,geometry.size.width-inset*2),height:max(1,geometry.size.height-(showsOverlapThumbnails ? 140 : showsComposition ? 12 : 48)))
            let baseRect=CropGeometry.aspectFit(video:(showsComposition || isCompleted) ? (model.project?.settings.aspectRatio ?? .portrait).size : source,container:area).offsetBy(dx:inset,dy:0)
            let zoom=selectionZoomEnabled ? min(4,max(1,selectionZoom*selectionPinch)) : 1
            let pan=clampedSelectionPan(CGSize(width:selectionPan.width+selectionDrag.width,height:selectionPan.height+selectionDrag.height),rect:baseRect,scale:zoom)
            let rect=CGRect(x:baseRect.midX-baseRect.width*zoom/2+pan.width,y:baseRect.midY-baseRect.height*zoom/2+pan.height,width:baseRect.width*zoom,height:baseRect.height*zoom)
            ZStack(alignment: .bottom) {
                ZStack {
                Group {
                    if isCompleted,let player=model.previewPlayer {
                        PlayerSurface(player:player).frame(width:rect.width,height:rect.height)
                            .position(x:rect.midX,y:rect.midY)
                    } else {
                        CompositionVideoViewport(model:model,source:source,viewport:rect.size,composition:showsComposition,
                            canvas:geometry.size,viewportOrigin:rect.origin,interactionEnabled:!timelineTrimming)
                    }
                }
                    .frame(width:geometry.size.width,height:geometry.size.height)
                    .accessibilityElement(children:showsComposition ? .contain : .ignore)
                    .accessibilityLabel(isCompleted ? "成片预览" : showsComposition ? "构图预览" : "原片画面")
                            .accessibilityIdentifier(showsComposition ? "compositionViewport" : "sourceVideoSurface")
                if !model.redactionEditing && !model.compositionEditing && model.controlsEnabled && (!model.hasCompletedTracking || isBlocked) && !isCompleted && !model.manualSelection && !model.isPlaying && !timelineTrimming {
                    ForEach(people, id: \.id) { person in
                        let number = person.number, box = person.box
                        Button { model.selectTarget(box) } label: {
                            CandidateCorners()
                                .stroke(.white.opacity(0.85),style:StrokeStyle(lineWidth:1.5,lineCap:.round))
                                .opacity(activeBox.map {$0.iou(box)>0.8} == true ? 0 : 1)
                                .frame(width:rect.width*box.width,height:rect.height*box.height)
                                .frame(minWidth:44,minHeight:44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .position(x: rect.minX + rect.width * box.center.x, y: rect.minY + rect.height * box.center.y)
                            .disabled(model.redactionIssue != nil && !model.canRedactPerson(box))
                            .accessibilityLabel(model.isDemo ? "选择舞者 \(number+1)" : "选择人物 \(number+1)")
                            .accessibilityIdentifier(model.isDemo ? "dancer\(number)" : "person\(number)")
                    }
                }
                if let box = activeBox, !isCompleted, !showsComposition && !model.manualSelection && !model.isPlaying {
                    TargetBox(label:"主角", warning: isBlocked && model.redactionIssue == nil, dashed: isProcessing && model.trackedSample?.estimated == true, badgeInside: rect.minY + rect.height * box.y < 34)
                        .frame(width: rect.width * box.width, height: rect.height * box.height)
                        .position(x: rect.minX + rect.width * box.center.x, y: rect.minY + rect.height * box.center.y)
                        .allowsHitTesting(false)
                }
                if model.manualSelection {
                    ManualBoxOverlay(box: $drawnBox).frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                }
                .frame(width:geometry.size.width,height:geometry.size.height)
                .mask(alignment:.top) {
                    Rectangle().frame(height:showsOverlapThumbnails ? max(1,geometry.size.height-140) : geometry.size.height)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(MagnifyGesture()
                    .updating($selectionPinch) {value,state,_ in state=value.magnification}
                    .onEnded {value in
                        selectionZoom=min(4,max(1,selectionZoom*value.magnification))
                        selectionPan=clampedSelectionPan(selectionPan,rect:baseRect,scale:selectionZoom)
                    },including:selectionZoomEnabled && !model.isPlaying ? .all : .none)
                .simultaneousGesture(DragGesture(minimumDistance:10)
                    .updating($selectionDrag) {value,state,_ in state=value.translation}
                    .onEnded {value in selectionPan=clampedSelectionPan(CGSize(width:selectionPan.width+value.translation.width,height:selectionPan.height+value.translation.height),rect:baseRect,scale:selectionZoom)},
                    including:selectionZoomEnabled && selectionZoom>1 && !model.isPlaying ? .all : .none)
                .accessibilityElement(children:.contain)
                .accessibilityIdentifier("analysisZoomCanvas")
                .accessibilityValue(String(format:"%.2f",Double(zoom)))
                .accessibilityAction(named:"放大人物画面") {if selectionZoomEnabled {selectionZoom=min(4,selectionZoom*1.5)}}
                if !isProcessing && !isCompleted && !model.compositionEditing && !showsOverlapThumbnails {
                    HStack(spacing: 8) {
                        if model.detecting || model.restoringTracking { ProgressView().tint(.white) }
                        Text(sourceHint).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(2)
                    }.padding(.horizontal, 20).frame(height: 44).padding(.bottom,58).allowsHitTesting(false)
                }
                if showsOverlapThumbnails,let project=model.project {
                    OverlappingPeoplePicker(people:overlapCandidates,projectID:project.id,
                        source:(model.player?.currentItem?.asset as? AVURLAsset)?.url,
                        sourceSize:source,time:model.currentTime,demo:model.isDemo,
                        preview:model.processingPreview,selected:activeBox,onSelect:{model.selectTarget($0)})
                        .frame(width:max(1,geometry.size.width-36),height:60)
                        .position(x:geometry.size.width/2,y:max(30,geometry.size.height-100))
                }
                playbackControl
                    .position(x:geometry.size.width/2,y:max(22,geometry.size.height-36))
                ZStack {
                    if selectionZoomEnabled && zoom>1.001 {
                        StudioIcon(symbol:"arrow.counterclockwise",label:"重置视频大小") {
                            withAnimation(reduceMotion ? nil : .smooth(duration:0.22)) {resetSelectionZoom()}
                        }
                        .accessibilityIdentifier("resetAnalysisZoom")
                        .transition(reduceMotion ? .identity : .opacity.combined(with:.offset(x:6)))
                    }
                }
                .frame(width:44,height:44)
                .animation(reduceMotion ? nil : .easeOut(duration:0.16),value:selectionZoomEnabled && zoom>1.001)
                .position(x:geometry.size.width/2+76,y:max(22,geometry.size.height-36))
            }
        }.clipped()
            .animation(reduceMotion ? nil : .smooth(duration:0.32),value:showsComposition)
            .animation(reduceMotion ? nil : .smooth(duration:0.32),value:model.project?.settings.aspectRatio)
    }
    private var sourceHint: String {
        if model.manualSelection { return model.detectionNotice ?? "拖动框体或方向微调 · 按住圆心偏移移动" }
        if let activity=model.editorActivityText {return activity}
        if model.phase == .editing,model.hasCompletedTracking,let project=model.project,
           project.settings.redaction.enabled,project.redactionPlan?.covers(project) != true {
            return "打码已更改 · 重新生成后可播放"
        }
        if model.redactionIssue != nil {return "轻点需要继续打码的同一人物"}
        if model.redactionEditing {return model.project?.settings.redaction.enabled == true ? "自动遮挡所有其他人物 · 主角保持清晰" : "打码已关闭"}
        if model.isReviewing {return model.detectionNotice ?? "选择同一主角后确认 · 黄色待确认，绿色已确认"}
        if isBlocked { return "轻点原片中的目标舞者" }
        if model.detecting { return "正在识别人物" }
        if let notice = model.detectionNotice { return notice }
        return "轻点人物进行选择"
    }
    private var reviewConfirmationDisabled:Bool {
        model.reviewSelection == nil || model.restoringTracking ||
            (model.analysisReview?.pending.isEmpty != true && model.currentReviewFrame?.body == model.reviewSelection)
    }
    @ViewBuilder private var recoveryDock: some View {
        if model.manualSelection {
            VStack(spacing: 12) {
                HStack(spacing:6) {
                    StudioTextButton(title:"取消",minWidth:44,fillsWidth:false) { model.manualSelection = false; drawnBox = nil }
                    Spacer(minLength:0)
                    ManualPositionControls(box:$drawnBox)
                    Spacer(minLength:0)
                    StudioTextButton(title:"重画",minWidth:44,fillsWidth:false) { drawnBox = nil }
                }
                StudioAction(title: "确认人物区域", disabled: drawnBox == nil) {
                    guard let box = drawnBox else { return }
                    if model.finishManualBox(box) {drawnBox=nil}
                }
                Spacer().frame(height: 10)
            }.padding(.horizontal, 24)
        } else if model.isReviewing {
            VStack(spacing:12) {
                HStack(alignment:.firstTextBaseline) {
                    Text("待确认 \(model.analysisReview?.pending.count ?? 0) / \(model.reviewFrames.count)")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("reviewPendingCount")
                    Spacer(minLength:8)
                }.lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing:12) {
                    StudioIcon(symbol:"chevron.left",label:"上一个待确认") {model.moveReview(-1)}
                        .disabled(!model.reviewFrames.contains {$0.body == nil && $0.time<model.currentTime-0.001})
                    Button {model.confirmReviewFrame()} label: {
                        HStack(spacing:8) {
                            Image(systemName:model.currentReviewFrame?.body == nil ? "checkmark" : "checkmark.circle")
                            Text(model.analysisReview?.pending.isEmpty == true ? "完成人物分析" : model.currentReviewFrame?.body == nil ? "确认此时刻" : "已确认")
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }.font(.subheadline.weight(.semibold))
                            .frame(maxWidth:.infinity).frame(height:48).contentShape(Capsule())
                    }.buttonStyle(.plain)
                        .modifier(StudioGlassSurface(shape:Capsule(),selected:!reviewConfirmationDisabled))
                        .disabled(reviewConfirmationDisabled).opacity(reviewConfirmationDisabled ? 0.4 : 1)
                        .accessibilityIdentifier("confirmReviewFrame")
                    StudioIcon(symbol:"chevron.right",label:"下一个待确认") {model.moveReview(1)}
                        .disabled(!model.reviewFrames.contains {$0.body == nil && $0.time>model.currentTime+0.001})
                }
                HStack(spacing:8) {
                    Button {model.retryCurrentReviewDetection()} label: {
                        HStack(spacing:6) {
                            if model.detecting {ProgressView().controlSize(.mini)}
                            else {Image(systemName:"arrow.clockwise")}
                            Text(model.detecting ? "识别中…" : "重新识别")
                        }.font(.caption.weight(.medium)).padding(.horizontal,12)
                            .frame(height:44).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("重新识别")
                        .modifier(StudioGlassSurface(shape:Capsule()))
                        .disabled(!model.canRetryReviewDetection)
                        .accessibilityIdentifier("retryReviewDetection")
                    Spacer(minLength:8)
                    Button {beginManual()} label: {
                        Label("手动框选",systemImage:"viewfinder")
                            .font(.caption.weight(.medium)).padding(.horizontal,12)
                            .frame(height:44).contentShape(Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("手动框选")
                        .modifier(StudioGlassSurface(shape:Capsule()))
                        .disabled(model.detecting || model.restoringTracking)
                        .accessibilityIdentifier("reviewManualSelection")
                }
            }.padding(.horizontal,24).padding(.bottom,8)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        } else if isBlocked {
            VStack(spacing: 10) {
                HStack(spacing: 24) {
                    StudioIcon(symbol: "backward.end.fill", label: "查看前一帧") { model.seek(to: model.currentTime - 0.2) }
                    StudioTextButton(title:"手动框选",minWidth:100,fillsWidth:false) { beginManual() }.font(.system(size:13)).modifier(StudioGlassSurface(shape: Capsule()))
                        .accessibilityLabel("手动框选人物")
                    StudioIcon(symbol: "forward.end.fill", label: "查看后一帧") { model.seek(to: model.currentTime + 0.2) }
                }
                StudioAction(title: "确认并继续", disabled: !model.canConfirm) { model.confirmProcessing() }
                Spacer().frame(height: 10)
            }.frame(maxWidth: .infinity)
        }
    }

    private var playbackControl:some View {
        StudioIcon(symbol:(isCompleted ? generatedPlaying : model.isPlaying) ? "pause.fill" : "play.fill",
                   label:(isCompleted ? generatedPlaying : model.isPlaying) ? "暂停预览" : "播放预览") {
                if isCompleted {
                    generatedPlaying.toggle()
                    if generatedPlaying {
                        if let player=model.previewPlayer,let end=player.currentItem?.duration.seconds,end.isFinite,player.currentTime().seconds>=end-0.1 {player.seek(to:.zero)}
                        model.previewPlayer?.play()
                    } else {model.previewPlayer?.pause()}
                }
                else {model.togglePreview()}
        }
        .accessibilityIdentifier("editorPlayback").keyboardShortcut(.space,modifiers:[])
        .disabled(isProcessing || model.isReviewing || model.manualSelection || timelineTrimming || (!isCompleted && model.hasCompletedTracking && model.project?.settings.redaction.enabled == true && model.project?.redactionPlan?.covers(model.project!) != true) || model.compositionEditing && !model.hasCompletedTracking)
    }

    private var playbackRow: some View {
        HStack {
            Text(model.currentTime.videoTime).foregroundStyle(.white)
                + Text(" / " + (model.project?.metadata.duration ?? 0).videoTime).foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(model.project?.settings.aspectRatio.rawValue ?? "16:9").foregroundStyle(.white.opacity(0.45)).frame(width: 60, alignment: .trailing)
        }.font(.system(.caption, design: .monospaced)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 26).frame(height: 44)
    }

    // Ending an editing session must not clear the selected settings tab.
    private var displayedTool:WorkspaceTool? {
        model.hasCompletedTracking && model.phase == .editing ? (activeTool ?? lastSettingsTool) : activeTool
    }
    private let bottomControlHeight:CGFloat = 56
    private var toolSelector:some View {
        NativeSegmentedControl(title:"编辑工具",options:availableTools,selection:Binding(
            get:{displayedTool ?? .composition},set:{selectTool($0)}
        ),label:{$0.rawValue},symbol:{$0.symbol},height:bottomControlHeight)
        .frame(height:bottomControlHeight)
        .accessibilityIdentifier("editorToolbar")
        .disabled(!model.settingsEnabled || timelineTrimming || model.compositionAdjusting)
    }
    private var bottomToolbar: some View {
        StudioGlassGroup(spacing: 12) {
            HStack(spacing: 12) {
                if model.hasCompletedTracking && !isProcessing && !isCompleted {
                    toolSelector
                }
                if isProcessing {
                    StudioTextButton(title:model.generatingVideo ? "取消生成" : "重新选择",height:56) {
                        if model.generatingVideo {model.cancelGeneration()}
                        else {activeTool=nil;model.reselectAnalysisTarget()}
                    }.font(.subheadline)
                        .buttonStyle(.plain).modifier(StudioGlassSurface(shape:Capsule()))
                }
                if isCompleted {completedActions} else {processingAction}
            }
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge).padding(.horizontal, 18).frame(height: 58)
    }
    private var processingAction:some View {
                Button {
                    if isProcessing {
                        if isPaused { model.resume() }
                    } else {
                        withAnimation(reduceMotion ? nil : .smooth(duration:0.28)) {
                            finishTool(commit:true);model.advanceWorkflow()
                        }
                    }
                } label: {
                    HStack(spacing:6) {
                        Text(isProcessing ? (model.generatingVideo ? "正在生成" : isPaused ? "继续分析" : model.phase.progress>=0.9 ? "补全片段" : "正在分析") : startTitle)
                            .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.5)
                        if isProcessing {
                            Image(systemName:isPaused ? "play.fill" : "pause.fill").font(.system(size:12))
                            Spacer(minLength:4)
                            Text(processingPercent).font(.subheadline.weight(.semibold)).monospacedDigit()
                                .lineLimit(1).fixedSize(horizontal:true,vertical:false).layoutPriority(1)
                                .contentTransition(.numericText()).accessibilityIdentifier("processingProgress")
                        } else {
                            Image(systemName:"arrow.right").font(.system(size:16,weight:.medium))
                        }
                    }.padding(.horizontal,14)
                        .frame(maxWidth:isProcessing || usesExpandedWorkspace || !model.hasCompletedTracking ? .infinity : nil).frame(width:isProcessing || usesExpandedWorkspace || !model.hasCompletedTracking ? nil : 132,height:bottomControlHeight)
                        .background {
                            if isProcessing {
                                ProcessingButtonFill(progress:min(1,max(0,model.phase.progress)),paused:isPaused)
                            }
                        }
                        .contentShape(Capsule())
                        .foregroundStyle(.white.opacity(isProcessing || canStart ? 1 : 0.3))
                }.buttonStyle(.plain).contentShape(Capsule())
                    .modifier(StudioGlassSurface(shape:Capsule(),selected:isProcessing || canStart))
                    .disabled(isProcessing ? !isPaused : !canStart)
                    .accessibilityLabel(isProcessing ? (model.generatingVideo ? "正在生成预览" : isPaused ? "继续分析" : model.phase.progress>=0.9 ? "正在补全未完成片段" : "正在分析人物") : startTitle)
                    .accessibilityValue(isProcessing ? processingPercent : "")
                    .accessibilityHint(isProcessing ? (isPaused ? "点按继续分析" : "请使用旁边的重新选择或取消操作") : "按当前工作台状态继续")
                    .accessibilityIdentifier("primaryAction")
    }
    private var completedActions:some View {
        HStack(spacing:12) {
            StudioTextButton(title:"返回修改",height:50) {generatedPlaying=false;model.backToEditor();selectTool(.composition)}
                .modifier(StudioGlassSurface(shape:Capsule()))
            #if targetEnvironment(macCatalyst)
            StudioTextButton(title:"导出视频",height:50) {savingFile=true}.modifier(StudioGlassSurface(shape:Capsule()))
            #else
            StudioTextButton(title:model.savedToPhotos ? "已保存" : "导出视频",height:50) {Task {await model.saveVideo()}}
                .disabled(model.savingToPhotos || model.savedToPhotos).modifier(StudioGlassSurface(shape:Capsule()))
            #endif
        }.buttonStyle(.plain).accessibilityIdentifier("completedActions")
    }
    private var usesExpandedWorkspace:Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }
    private var editorTimeline:some View {
        VStack(spacing:0) {
            playbackRow
            TrimTimeline(model:model,onEditingChanged:{ editing in
                timelineTrimming=editing
                if editing && isCompleted {generatedPlaying=false;model.previewPlayer?.pause()}
            })
                .coordinateSpace(.named("timeline")).padding(.horizontal,18)
                .disabled(isProcessing || (isBlocked && !model.isReviewing)).allowsHitTesting(!isProcessing && (!isBlocked || model.isReviewing))
        }
    }
    private var expandedControls:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Image(systemName:isProcessing ? "viewfinder" : displayedTool?.symbol ?? "person.crop.circle")
                    .foregroundStyle(Color.acAccent)
                Text(isBlocked ? "确认主角" : isProcessing ? (isPaused ? "处理已暂停" : "正在跟随主角") : displayedTool?.rawValue ?? "主角选择")
                    .font(.headline)
                Spacer(minLength:0)
            }.padding(.horizontal,18).padding(.top,20)
            if isBlocked || model.manualSelection {
                recoveryDock.frame(height:model.manualSelection ? 244 : 180)
            } else if isProcessing {
                Text(model.generatingVideo ? "正在生成预览" : isPaused ? "分析已暂停" : "正在分析人物").font(.subheadline).padding(.horizontal,18)
            } else if isCompleted {completedActions}
            else if let tool=displayedTool {
                inlineSettings(tool).fixedSize(horizontal:false,vertical:true)
            } else {
                VStack(alignment:.leading,spacing:12) {
                    Text(model.project?.target == nil ? "在原片中轻点主角" : "主角已选中")
                        .font(.title3.weight(.semibold))
                    Text("点击画面选择主角，拖动时间轴两端截取。")
                        .font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                    if model.observations.isEmpty && model.detectionNotice != nil {StudioTextButton(title:"手动框选",fillsWidth:false,action:beginManual).font(.subheadline)}
                }.padding(.horizontal,18)
            }
            Spacer(minLength:0)
            if !isBlocked && !model.manualSelection {bottomToolbar.padding(.bottom,12)}
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }

    private var processingPercent:String {
        min(isProcessing ? 0.99 : 1,max(0,model.phase.progress)).formatted(.percent.precision(.fractionLength(0)))
    }
    private var canStart: Bool { !timelineTrimming && model.canConfirm }
    private var startTitle: String {
        if !model.hasCompletedTracking {return model.detecting ? "正在识别人物…" : "分析所选片段"}

        if model.restoringTracking {return "正在恢复项目…"}
        if model.detecting {return "正在识别人物…"}
        if model.isPlaying {return "请先暂停预览"}
        if model.needsRegeneration {return "重新生成"}

        return model.hasReusableOutput ? "预览成片" : "生成预览"
    }

    private func selectTool(_ tool: WorkspaceTool) {
        guard model.hasCompletedTracking,!model.compositionAdjusting else { return }
        guard activeTool != tool else {return}
        model.pausePreview(refresh: false)
        if model.redactionEditing && tool != .redaction {model.finishRedaction(commit:true,keepComposition:true)}
        if tool == .composition || tool == .motion {model.beginComposition();guard model.compositionEditing else {return}}
        if tool == .redaction {model.beginRedaction()}
        activeTool=tool;lastSettingsTool=tool
    }
    private func finishTool(commit: Bool) {
        guard let tool = activeTool else { return }
        if commit && model.compositionAdjusting { return }
        switch tool {
        case .composition, .motion: model.finishComposition(commit: commit,refreshDetections:false)
        case .redaction: model.finishRedaction(commit:commit)
        }
        activeTool = nil
    }
    private func beginManual() {
        guard model.controlsEnabled else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            finishTool(commit: true)
            model.beginManualSelection()
            drawnBox = model.reviewSelection ?? model.project?.target ?? .init(x: 0.32, y: 0.12, width: 0.36, height: 0.76)
        }
    }

    private var settingsPanelAnimation:Animation? {reduceMotion ? nil : .smooth(duration:0.24,extraBounce:0)}
    private func inlineSettings(_ tool:WorkspaceTool)->some View {
        settingsPanel(tool).padding(.horizontal,18)
            .accessibilityElement(children:.contain).accessibilityIdentifier("adjustmentPanel")
    }
    private func settingsPanel(_ tool:WorkspaceTool)->some View {
        // The explicit outer frame alone owns height. Outgoing controls in the overlay
        // cannot retain their old intrinsic height or stretch the incoming controls.
        Color.clear.overlay(alignment:.top) {
            VStack(spacing:0) {
                switch tool {
                case .composition: compositionPanel
                case .motion: motionPanel
                case .redaction: redactionPanel
                }
            }
            .frame(maxWidth:.infinity)
            .id(tool)
            .transition(reduceMotion ? .identity : .opacity.combined(with:.offset(y:6)))
            .zIndex(1)
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    // Shared control sizing and spacing for phone, wide layouts and Mac Catalyst.
    private let panelInset:CGFloat = 12
    private var redactionPanel: some View {
        VStack(spacing:8) {
            HStack(spacing:0) {
                Toggle(isOn:Binding(
                    get:{model.project?.settings.redaction.enabled == true},
                    set:{if $0 {model.enableAutomaticRedaction()} else {model.clearRedactions()}}
                )) {
                    HStack(spacing:4) {
                        Text("打码")
                        Button {showRedactionHelp=true} label: {
                            Image(systemName:"questionmark.circle").font(.subheadline)
                                .frame(width:44,height:44,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("打码说明").accessibilityIdentifier("redactionHelp")
                        .popover(isPresented:$showRedactionHelp,attachmentAnchor:.point(UnitPoint(x:0.18,y:0.5)),arrowEdge:.bottom) {
                            Text("对主角外人物进行打码")
                                .font(.subheadline).padding(16)
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                }
                .font(.subheadline.weight(.medium)).toggleStyle(.switch)
                .accessibilityIdentifier("redactionEnabled")
                ZStack {
                if model.project?.settings.redaction.enabled == true {
                Menu {
                    Picker("打码范围",selection:Binding(
                        get:{model.project?.settings.redaction.region ?? .face},
                        set:{model.setRedactionRegion($0)}
                    )) {
                        ForEach(RedactionSettings.Region.allCases,id:\.self) {region in
                            Text(region == .face ? "人脸" : "全身").tag(region)
                        }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    HStack(spacing:5) {
                        Text(model.project?.settings.redaction.region == .person ? "全身" : "人脸")
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Image(systemName:"chevron.down").font(.caption2.weight(.semibold))
                    }.font(.subheadline).padding(.horizontal,10).frame(minWidth:76,minHeight:44)
                        .background(.white.opacity(0.06),in:Capsule())
                }.accessibilityLabel("打码范围")
                    .accessibilityValue(model.project?.settings.redaction.region == .person ? "全身" : "人脸")
                    .accessibilityIdentifier("redactionRegionMenu")
                    .transition(reduceMotion ? .identity : .opacity.combined(with:.offset(y:4)))
                }
                }.frame(width:model.project?.settings.redaction.enabled == true ? 88 : 0,height:44)
                    .padding(.leading,model.project?.settings.redaction.enabled == true ? 12 : 0)
            }.frame(height:44)
                .animation(reduceMotion ? nil : .easeInOut(duration:0.28),value:model.project?.settings.redaction.enabled)
            NativeSegmentedControl(title:"打码样式",options:RedactionSettings.Style.allCases.filter {model.project?.settings.redaction.region != .person || $0 != .image},selection:Binding(
                get:{model.project?.settings.redaction.style ?? .frosted},set:{model.setRedactionStyle($0)}
            ),label:{$0 == .image ? "贴片" : $0.rawValue})
            .frame(height:48).accessibilityIdentifier("redactionStyle")
            HStack(spacing:10) {
                if model.project?.settings.redaction.style == .image {
                    stickerChoices
                } else {
                    Text("强度").font(.caption)
                    Slider(value:Binding(
                        get:{(model.project?.settings.redaction.strength ?? RedactionSettings.defaultStrength)*100},
                        set:{model.setRedactionStrength($0/100)}
                    ),in:0...100,step:1)
                    .tint(.white).accessibilityLabel("打码强度")
                    .accessibilityValue("\(RedactionSettings.displayStrength(model.project?.settings.redaction.strength ?? RedactionSettings.defaultStrength))")
                    .accessibilityIdentifier("redactionStrength")
                    Text("\(RedactionSettings.displayStrength(model.project?.settings.redaction.strength ?? RedactionSettings.defaultStrength))")
                        .font(.caption.monospacedDigit()).frame(width:34,alignment:.trailing)
                        .accessibilityHidden(true)
                }
            }.frame(height:44)
        }.padding(12)
            .modifier(StudioGlassSurface(shape:RoundedRectangle(cornerRadius:24),interactive:false))
            .accessibilityElement(children:.contain)
    }
    private var stickerChoices:some View {
        ForEach(RedactionSticker.allCases) {sticker in
            Button {model.setRedactionSticker(sticker)} label: {
                if let image=sticker.image {
                    Image(uiImage:image).resizable().scaledToFit().frame(width:34,height:34)
                        .frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())
                        .background(model.project?.settings.redaction.imageData == sticker.data ? .white.opacity(0.16) : .clear,in:RoundedRectangle(cornerRadius:12))
                }
            }.buttonStyle(.plain).accessibilityLabel(sticker.title+"贴片")
                .accessibilityIdentifier("redactionSticker-"+sticker.rawValue)
                .accessibilityAddTraits(model.project?.settings.redaction.imageData == sticker.data ? .isSelected : [])
        }
    }
    private var motionPanel: some View {
        VStack(alignment:.leading,spacing:12) {
            NativeSegmentedControl(title:"运镜速度",options:EditSettings.FollowSpeed.allCases,selection:Binding(
                get:{model.project?.settings.followSpeed ?? .gentle},set:{model.setFollowSpeed($0)}
            ),label:{$0.rawValue})
            .frame(height:48).accessibilityIdentifier("motionSpeed")
            .disabled(compositionControlsDisabled)
            Text(motionDescription)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(panelInset)
            .modifier(StudioGlassSurface(shape:RoundedRectangle(cornerRadius:24),interactive:false))
    }
    private var motionDescription:String {
        switch model.project?.settings.followSpeed ?? .gentle {
        case .gentle: "平缓跟随主角，减少画面移动。"
        case .standard: "兼顾画面稳定与跟随速度。"
        case .responsive: "快速跟随主角，适合大幅移动。"
        }
    }
    private var compositionPanel: some View {
        VStack(spacing:6) {
            NativeSegmentedControl(title:"画面比例",options:OutputAspectRatio.allCases,selection:Binding(
                get:{model.project?.settings.aspectRatio ?? .portrait},set:{model.setCompositionAspect($0)}
            ),label:{$0.rawValue})
            .frame(height:48)
            .accessibilityIdentifier("compositionAspect")
            .disabled(compositionControlsDisabled)
            HStack(spacing: 0) {
                compositionControl("缩小", symbol: "minus.magnifyingglass") { model.compositionZoom(1 / 1.1) }
                compositionControl("放大", symbol: "plus.magnifyingglass") { model.compositionZoom(1.1) }
                Rectangle().fill(.white.opacity(0.12)).frame(width: 0.5, height: 28).padding(.horizontal, 4)
                compositionControl("水平居中", symbol: "align.horizontal.center") { model.centerComposition(horizontal: true) }
                compositionControl("垂直居中", symbol: "align.vertical.center") { model.centerComposition(horizontal: false) }
            }.disabled(compositionControlsDisabled)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(model.editorActivityText ?? model.compositionNotice ?? "拖动位置 · 双指缩放")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
        }.padding(panelInset)
            .modifier(StudioGlassSurface(shape: RoundedRectangle(cornerRadius: 24), interactive: false))
    }
    private var compositionControlsDisabled: Bool { timelineTrimming || model.compositionAdjusting }
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
        if model.isReviewing {return model.reviewSelection}
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
}

struct TargetBox:View {
    let label:String
    var warning:Bool
    var dashed:Bool
    var badgeInside = false
    private var tint:Color { warning ? .orange : .acAccent }
    var body:some View {
        GeometryReader { _ in
            Rectangle()
                .stroke(tint.opacity(0.5),style:StrokeStyle(lineWidth:1,dash:dashed ? [4,3] : []))
                .overlay {
                    CandidateCorners().stroke(tint,style:StrokeStyle(lineWidth:3,lineCap:.square,lineJoin:.miter))
                }
                .overlay(alignment:.topLeading) {
                    Text(label).font(.system(size:10,weight:.medium))
                    .lineLimit(1).fixedSize(horizontal:true,vertical:false)
                    .padding(.horizontal,8).frame(height:24)
                    .foregroundStyle(Color.acOnAccent)
                    .background(tint,in:RoundedRectangle(cornerRadius:4))
                    .offset(y:badgeInside ? 6 : -30)
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
