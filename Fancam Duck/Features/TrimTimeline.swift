import SwiftUI

struct TrimTimeline:View {
    @Bindable var model:AppModel
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var draftRange: ClosedRange<Double>?
    @State private var referenceTime = 0.0
    @State private var scrubbing = false
    @GestureState private var draggingPlayhead = false
    @GestureState private var draggingHandle = false
    private var canTrim: Bool {
        model.settingsEnabled && !model.manualSelection && !model.compositionAdjusting
    }
    var body:some View {
        if let project=model.project {
            VStack(spacing:8) {
                GeometryReader { geometry in
                    let width=max(1,geometry.size.width-44),duration=max(0.01,project.metadata.duration)
                    let range = draftRange ?? project.settings.start...project.settings.end
                    let startX=22+width*range.lowerBound/duration,endX=22+width*range.upperBound/duration
                    ZStack(alignment:.leading) {
                        HStack(spacing:1) {
                            ForEach(0..<8,id:\.self) { index in
                                if model.thumbnails.indices.contains(index) { Image(uiImage:model.thumbnails[index]).resizable().scaledToFill().frame(width:width/8,height:48).clipped() }
                                else if model.isDemo { DemoStage(time:Double(index)*2,target:nil).frame(width:width/8,height:48) }
                                else { Color.gray.opacity(0.2).frame(width:width/8,height:48) }
                            }
                        }.frame(width:width,height:48).clipShape(RoundedRectangle(cornerRadius:8)).offset(x:22)
                            .contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0)
                            .updating($draggingPlayhead) {_,dragging,_ in dragging=true}
                            .onChanged { value in
                                guard (model.controlsEnabled || model.canScrubGeneratedPreview) && !model.manualSelection && (!model.compositionEditing || model.hasCompletedTracking) else { return }
                                if !scrubbing {scrubbing=true;onEditingChanged(true)}
                                model.scrub(to:value.location.x/width*duration)
                            }.onEnded {_ in
                                finishScrub()
                            })
                        Rectangle().fill(.black.opacity(0.55)).frame(width:max(0,startX-22),height:48).offset(x:22).allowsHitTesting(false)
                        Rectangle().fill(.black.opacity(0.55)).frame(width:max(0,22+width-endX),height:48).offset(x:endX).allowsHitTesting(false)
                        RoundedRectangle(cornerRadius:6).strokeBorder(Color.white,lineWidth:2).frame(width:max(0,endX-startX),height:48).offset(x:startX).allowsHitTesting(false)
                        handle(true,x:startX,width:width,duration:duration)
                        handle(false,x:endX,width:width,duration:duration)
                        ForEach(model.reviewFrames) {frame in
                            Button {model.selectReviewFrame(at:frame.time)} label: {
                                Rectangle().fill(frame.body == nil ? Color.yellow : Color.green)
                                    .frame(width:2,height:44)
                                    .frame(width:18,height:44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .position(x:22+width*frame.time/duration,y:26)
                                .accessibilityLabel((frame.body == nil ? "待确认 " : "已确认 ")+String(format:"%.3f 秒",frame.time))
                                .accessibilityIdentifier("reviewMarker-\(frame.id)")
                                .accessibilityValue(frame.body == nil ? "待确认" : "已确认")
                        }
                        Capsule().fill(.white).frame(width:2,height:52).shadow(color:.black.opacity(0.5),radius:1).offset(x:22+width*model.currentTime/duration).allowsHitTesting(false)
                    }
                }.frame(height:52)
                Text("\((draftRange?.lowerBound ?? project.settings.start).videoTime) — \((draftRange?.upperBound ?? project.settings.end).videoTime)")
                    .font(.system(size:11,design:.monospaced)).foregroundStyle(.white.opacity(0.65))
                    .accessibilityLabel("选中片段")
                    .accessibilityValue("起点 \((draftRange?.lowerBound ?? project.settings.start).videoTime)，终点 \((draftRange?.upperBound ?? project.settings.end).videoTime)，当前 \(model.currentTime.videoTime)")

            }.accessibilityElement(children: .contain).accessibilityIdentifier("trimTimeline")
                .onChange(of:draggingPlayhead) {_,dragging in if !dragging {finishScrub()}}
                .onChange(of: draggingHandle) { _, dragging in
                    if !dragging { cancelTrim() }
                }
                .onDisappear {
                    if scrubbing {scrubbing=false;onEditingChanged(false)}
                    cancelTrim()
                }
        }
    }
    private func finishScrub() {
        guard scrubbing else {return}
        scrubbing=false
        if model.route == .editor {model.finishScrubbing()}
        onEditingChanged(false)
    }
    private func handle(_ isStart:Bool,x:Double,width:Double,duration:Double) -> some View {
        RoundedRectangle(cornerRadius:6).fill(Color.white).frame(width:18,height:48)
            .overlay { Capsule().fill(Color.black.opacity(0.8)).frame(width:3,height:18) }
            .frame(width:44,height:52).contentShape(Rectangle()).offset(x:x-22)
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("timeline"))
                .updating($draggingHandle) { _, dragging, _ in dragging = true }
                .onChanged { value in
                guard canTrim else { return }
                let time=(value.location.x-22)/width*duration
                adjust(isStart: isStart, time: time)
            }.onEnded { _ in finishTrim(isStart: isStart) })
            .accessibilityElement().accessibilityLabel(isStart ? "裁剪起点" : "裁剪终点")
            .opacity(canTrim ? 1 : 0.35).allowsHitTesting(canTrim)
            .accessibilityValue((isStart ? (draftRange?.lowerBound ?? model.project?.settings.start) : (draftRange?.upperBound ?? model.project?.settings.end))?.videoTime ?? "")
            .accessibilityAdjustableAction { direction in
                guard canTrim else { return }
                let current=(isStart ? (draftRange?.lowerBound ?? model.project?.settings.start) : (draftRange?.upperBound ?? model.project?.settings.end)) ?? 0
                let next=current+(direction == .increment ? 0.1 : -0.1)
                adjust(isStart: isStart, time: next)
                finishTrim(isStart: isStart)
            }
    }
    private func adjust(isStart: Bool, time: Double) {
        guard canTrim, let project = model.project else { return }
        if draftRange == nil {
            referenceTime = model.currentTime
            draftRange = project.settings.start...project.settings.end
            onEditingChanged(true)
        }
        let bounds=model.trimBounds ?? 0...project.metadata.duration
        let range = draftRange!, minimum = min(0.5, bounds.upperBound-bounds.lowerBound)
        if isStart {
            draftRange = min(max(bounds.lowerBound,time),range.upperBound-minimum)...range.upperBound
        } else {
            draftRange = range.lowerBound...min(bounds.upperBound,max(range.lowerBound+minimum,time))
        }
        model.scrub(to: isStart ? draftRange!.lowerBound : draftRange!.upperBound,
                    within:bounds,sourceOnly:true)
    }
    private func cancelTrim() {
        guard draftRange != nil else { return }
        draftRange = nil
        onEditingChanged(false)
        if model.route == .editor, model.phase == .editing, let project = model.project {
            model.scrub(to: referenceTime, within: 0...project.metadata.duration, sourceOnly: true)
            model.finishScrubbing()
        }
    }
    private func finishTrim(isStart: Bool) {
        guard let range = draftRange else { return }
        model.updateRange(start: range.lowerBound, end: range.upperBound,
                          previewTime: isStart ? range.lowerBound : range.upperBound)
        draftRange = nil
        onEditingChanged(false)
        model.persist()
    }
}
