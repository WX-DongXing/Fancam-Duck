import SwiftUI
import AVFoundation
import Observation

@MainActor @Observable
final class AppModel {
    enum Route { case home, editor, export }
    var route: Route = .home
    var projects: [VideoProject] = []
    var project: VideoProject?
    var phase: ProcessingPhase = .editing
    var targetExplicitlySelected = false
    var currentTime: Double = 0
    var manualSelection = false
    var selectedTool: EditorTool?
    var thumbnails: [UIImage] = []
    var player: AVPlayer?
    var observations: [PersonObservation] = []
    private var analyzedPeople:[Int:DetectionBatch]=[:]
    var analysisReview:AnalysisReview?
    var reviewSelection:NormalizedRect?
    private var reviewID=UUID()
    private var reviewTasks:[Int:Task<Void,Never>]=[:]
    var isReviewing:Bool {analysisReview != nil && !hasCompletedTracking}
    var reviewFrames:[AnalysisReviewFrame] {analysisReview?.frames ?? []}
    var currentReviewFrame:AnalysisReviewFrame? {reviewFrames.first {abs($0.time-currentTime)<0.001}}

    private var selectionObservation:PersonObservation?
    var processingPreview: CGImage?
    var trackedSample: TargetSample?
    var targetSamples: [TargetSample] = []
    var detecting = false
    var detectionNotice:String?
    private var processingMessage:String?
    var restoringTracking=false
    private var restorationID=UUID()
    private var restorationTask:Task<Void,Never>?
    var savingToPhotos=false
    private let photoSaver:any PhotoSaving
    var previewPlayer: AVPlayer?
    var exportPoster:CGImage?
    var exportProgress:Double=0
    var cancellingExport=false
    private struct GenerationRecipe:Equatable {
        let projectID:UUID
        let sourceFileName:String?
        let metadata:VideoMetadata
        let target:NormalizedRect?
        let targetTime:Double
        let settings:EditSettings
        init(_ project:VideoProject) {
            projectID=project.id;sourceFileName=project.sourceFileName;metadata=project.metadata
            target=project.target;targetTime=project.targetTime;settings=project.settings
        }
    }
    private var lastGeneratedRecipe:GenerationRecipe?
    var needsRegeneration:Bool {
        guard let project,let recipe=lastGeneratedRecipe,recipe.projectID==project.id else {return false}
        return recipe != GenerationRecipe(project)
    }
    private var outputSettings:EditSettings?
    var hasReusableOutput:Bool {
        guard let project,let outputURL,outputSettings==project.settings,lastGeneratedRecipe==GenerationRecipe(project) else {return false}
        return FileManager.default.fileExists(atPath:outputURL.path)
    }
    private var compositionAutomaticSettings:EditSettings?
    var importingRedactionImage=false
    private var redactionImageID=UUID()
    var redactionEditing=false
    var redactionIssue: RedactionIssue?
    private var redactionSnapshot: RedactionSettings?
    private var redactionPlanSnapshot: RedactionPlan?
    private var redactionPreviewTask: Task<Void,Never>?
    private var redactionPreviewID=UUID()
    var compositionEditing=false
    var compositionAdjusting=false
    var compositionBusy=false
    var compositionCrop:CGRect?
    var compositionNotice:String?
    private var analysisOnly=false
    private var generateAfterAnalysis=false
    private var generationAnalysisWeight=0.0
    private var generationRedactionWeight=0.0
    var generatingVideo=false
    var hasCompletedTracking=false
    private var compositionSnapshot:EditSettings?
    private var compositionUndo:[EditSettings]=[]
    private var compositionGestureSettings:EditSettings?
    private var compositionAutomatic:CGRect?
    private var compositionFrames:[CropPlan.Frame]=[]
    private var compositionAutomaticFrames:[CropPlan.Frame]=[]
    private var compositionTask:Task<Void,Never>?
    private var compositionID=UUID()
    var compositionDisplayedScale:Double {
        guard let automatic=compositionAutomatic,let crop=compositionCrop,crop.height>0 else {return project?.settings.compositionScale ?? 1}
        return automatic.height/crop.height
    }
    private var detectionTask: Task<Void, Never>?
    var isPlaying = false
    private var previewTask: Task<Void,Never>?
    var importing = false
    var errorMessage: String?
    var showGuide = false
    var outputURL: URL?
    var savedToPhotos = false
    private var processingTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private let store: ProjectStore
    private let pipeline: any TargetTracking
    private let exporter:any VideoExporting
    private var operationID=UUID()
    private var detectionID=UUID()
    private var importID=UUID()
    private var persistenceTask:Task<Void,Never>?


    init(store: ProjectStore = .shared, pipeline: any TargetTracking = CoreMLTrackingPipeline(), exporter:any VideoExporting = VideoExporter(),photoSaver:any PhotoSaving = MediaService.shared) {
        self.store = store
        self.pipeline = pipeline
        self.exporter = exporter
        self.photoSaver = photoSaver
    }
    var isDemo: Bool { project?.isDemo == true }
    var canConfirm: Bool {
        guard !isReviewing,!restoringTracking,!detecting,!importingRedactionImage,!isPlaying,!manualSelection,(!compositionBusy || hasCompletedTracking),!compositionAdjusting,let project,
              (hasCompletedTracking || hasReusableOutput || (project.targetTime>=project.settings.start && project.targetTime<=project.settings.end)) else { return false }
        return ProcessingGate.canContinue(phase: phase, target: project.target, explicitlySelected: targetExplicitlySelected)
    }
    var controlsEnabled: Bool { phase.canEditTarget }
    var settingsEnabled: Bool { phase == .editing && !restoringTracking }
    var editorActivityText: String? {
        if restoringTracking {return "正在恢复项目 · 设置稍后可用"}
        if compositionBusy && !hasCompletedTracking {return "正在准备构图预览 · 可取消"}
        if importingRedactionImage {return "正在准备遮挡图片"}
        if detecting {return project?.target == nil ? "正在识别人物 · 请稍候" : "正在识别当前帧 · 可调整设置"}
        return nil
    }
    var statusText: String {
        switch phase {
        case .editing:
            if restoringTracking {return "正在恢复已分析结果"}
            if let detectionNotice {return detectionNotice}
            return project?.target == nil ? (isDemo ? "轻点视频中的舞者" : (detecting ? "正在识别人物" : "轻点视频中的人物 · 可框选辅助识别")) : "已选择目标 · 确认后开始处理"
        case .processing: if let processingMessage {return processingMessage};return trackedSample?.estimated == true ? "短暂遮挡 · 正在自动找回" : "正在跟随目标舞者"
        case .paused: return "处理已暂停"
        case .blocked: return targetExplicitlySelected ? "目标已重新选择，请确认后继续" : "处理已阻塞 · 请重新指定人物"
        case .readyToExport: return "处理完成"
        case .exporting: return "正在导出"
        case .completed: return isDemo ? "演示流程已完成" : "视频已导出"
        }
    }
    #if DEBUG
    func prepareHistoryUITest() async {
        var keep=VideoProject.demo;keep.title="保留的测试项目"
        var removable=VideoProject.demo;removable.title="侧滑删除测试项目";removable.updatedAt=Date().addingTimeInterval(1)
        do { try await store.save(keep);try await store.save(removable) }
        catch { errorMessage=error.localizedDescription }
    }
    #endif
    func loadProjects() async {
        do { projects = try await store.projects() }
        catch { errorMessage = "项目记录读取失败：\(error.localizedDescription)" }
    }
    func startDemo() {
        cancelTasks()
        project = .demo;lastGeneratedRecipe=nil
        phase = .editing
        route = .editor
        currentTime = 0
        thumbnails = []
        player = nil
        targetExplicitlySelected = false
        selectedTool = nil
        manualSelection = false
        outputURL = nil
        savedToPhotos = false
    }
    func importMovie(_ movie: ImportedMovie) async {
        let id=UUID();importID=id
        importing = true
        defer {
            if importID==id { importing=false }
            try? FileManager.default.removeItem(at: movie.url)
        }
        var copied:URL?
        var savedProject:VideoProject?
        do {
            try Task.checkCancellation()
            let source=try await store.importFile(movie.url)
            copied=source
            guard importID==id else { throw CancellationError() }
            try Task.checkCancellation()
            let metadata=try await MediaService.shared.metadata(url:source)
            guard importID==id else { throw CancellationError() }
            try Task.checkCancellation()
            var settings = EditSettings()
            settings.end = metadata.duration
            let sizes = OutputResolution.available(for: metadata)
            guard let preferred = sizes.last(where: { $0.width <= 1080 }) ?? sizes.first else { throw MediaError.noVideo }
            settings.resolution = preferred
            let project = VideoProject(title: movie.url.deletingPathExtension().lastPathComponent == "" ? "新的舞蹈视频" : "舞蹈视频 · \(Date().formatted(date: .numeric, time: .omitted))", sourceFileName: source.lastPathComponent, metadata: metadata, settings: settings)
            try await store.save(project)
            savedProject=project
            guard importID==id,!Task.isCancelled else {
                try await store.remove(project);return
            }
            open(project)
            await loadProjects()
        } catch {
            if let savedProject { try? await store.remove(savedProject) }
            else if let copied { try? FileManager.default.removeItem(at:copied) }
            if importID==id,!Task.isCancelled,!(error is CancellationError) { errorMessage=error.localizedDescription }
        }
    }
    func open(_ savedProject:VideoProject) {
        cancelTasks();lastGeneratedRecipe=nil
        var project=savedProject
        project.normalizeOutputAspect()
        if !project.settings.redaction.allOthers && !project.settings.redaction.subjects.isEmpty {
            project.settings.redaction.allOthers=true;project.settings.redaction.subjects=[];project.redactionPlan=nil
        }
        let conflicts=RedactionPolicy.conflicts(project:project,samples:[])
        if !conflicts.isEmpty {
            project.settings.redaction.subjects.removeAll {conflicts.contains($0.id)};project.redactionPlan=nil
        }
        if !project.targetTime.isFinite {
            project.target=nil;project.targetTime=project.settings.start
        }
        self.project = project
        route = .editor
        phase = .editing
        currentTime = project.target == nil ? project.settings.start : min(project.settings.end,max(project.settings.start,project.targetTime))
        manualSelection = false
        selectedTool = nil
        targetExplicitlySelected = false
        thumbnails = []
        outputURL = nil;outputSettings=nil
        savedToPhotos = false
        if let url = store.sourceURL(for: project) {
            player = AVPlayer(url: url)
            thumbnailTask = Task { [weak self] in
                let images = await MediaService.shared.thumbnails(url: url, duration: project.metadata.duration)
                guard !Task.isCancelled, self?.project?.id == project.id else { return }
                self?.thumbnails = images
            }
            restoringTracking=true
            seek(to: currentTime)
            let restoreID=UUID();restorationID=restoreID
            let previousSave=persistenceTask
            restorationTask=Task { [weak self,store=self.store] in
                await previousSave?.value
                let review=try? await store.review(for:project)
                let analysis=try? await store.analysis(for:project)
                let cached=analysis?.samples,people=analysis?.people
                let output=try? await store.output(for:project)
                guard let self,!Task.isCancelled,self.restorationID==restoreID,self.project?.id==project.id else {return}
                if let people,let source=store.sourceURL(for:project) {await self.pipeline.restorePeople(people,source:source)}
                guard !Task.isCancelled,self.restorationID==restoreID,self.project?.id==project.id else {return}
                self.restoringTracking=false;self.analyzedPeople=people ?? [:]
                if let output {self.outputURL=output.url;self.outputSettings=project.settings;self.savedToPhotos=output.savedToPhotos;self.lastGeneratedRecipe=GenerationRecipe(project)}
                if let cached {
                    self.targetSamples=cached;self.hasCompletedTracking=true
                    if let current=self.project {
                        let conflicts=RedactionPolicy.conflicts(project:current,samples:cached)
                        if !conflicts.isEmpty {
                            self.project?.settings.redaction.subjects.removeAll {conflicts.contains($0.id)}
                            self.project?.redactionPlan=nil;self.outputURL=nil;self.outputSettings=nil;self.savedToPhotos=false
                            self.persist()
                        }
                    }
                    if let anchor=project.settings.compositionAnchor {
                        self.seek(to:min(project.settings.end,max(project.settings.start,anchor.time)))
                    }
                }
                else if output == nil && (project.targetTime<project.settings.start || project.targetTime>project.settings.end) {
                    self.project?.target=nil;self.project?.settings.compositionAnchor=nil;self.targetExplicitlySelected=false
                }
                if let review,cached == nil {
                    self.analysisReview=review;self.targetSamples=review.samples;self.analyzedPeople=review.people
                    if review.pending.isEmpty {self.completeReview()}
                    else {self.selectReviewFrame(at:review.pending[0].time)}
                    return
                }
                self.detectPeople();self.refreshRedactionPreview()
            }
        } else { player = nil }
    }
    func selectTarget(_ rect: NormalizedRect) {
        if isReviewing {
            guard !restoringTracking,rect.isValid,rect.width>0.015,rect.height>0.03 else {return}
            reviewSelection=rect;targetExplicitlySelected=true;return
        }
        guard controlsEnabled, rect.isValid, rect.width > 0.015, rect.height > 0.03 else { return }
        if let issue=redactionIssue {
            guard canRedactPerson(rect) else {detectionNotice="主角不参与打码";return}
            if let index=project?.settings.redaction.subjects.firstIndex(where:{$0.id==issue.subjectID}) {
                project?.settings.redaction.subjects[index].anchors.removeAll {abs($0.time-currentTime)<0.051}
                project?.settings.redaction.subjects[index].anchors.append(.init(time:currentTime,body:rect))
                project?.redactionPlan=nil;targetExplicitlySelected=true;refreshRedactionPreview();persist()
            }
            return
        }
        if redactionEditing {if project?.settings.redaction.allOthers != true {toggleRedaction(rect)};return}
        // Resolve against the previous mask tracks before replacing the camera target.
        if let id=redactionSubject(at:rect) {
            project?.settings.redaction.subjects.removeAll {$0.id==id};project?.redactionPlan=nil
        }
        restorationID=UUID();restorationTask?.cancel();restoringTracking=false
        hasCompletedTracking=false;targetSamples=[];analyzedPeople=[:];outputSettings=nil;outputURL=nil;savedToPhotos=false
        selectionObservation=observations.filter {$0.body.iou(rect)>0.7}.max {$0.body.iou(rect)<$1.body.iou(rect)}
        if phase.issue == nil {project?.settings.compositionAnchor=nil}
        project?.redactionPlan=nil
        project?.target = rect
        project?.targetTime = currentTime
        targetExplicitlySelected = true
        manualSelection = false
        refreshRedactionPreview();persist()
    }
    func advanceWorkflow() {
        analysisOnly = !hasCompletedTracking
        generateAfterAnalysis = hasCompletedTracking
        confirmProcessing()
    }
    func confirmProcessing() {
        guard !isReviewing else {return}
        if redactionEditing {finishRedaction(commit:true)}
        if compositionEditing { finishComposition(commit:true,refreshDetections:false) }
        guard canConfirm, let project else { return }
        pausePreview(refresh:false)
        if hasReusableOutput,let outputURL {
            previewPlayer=AVPlayer(url:outputURL);phase = .completed(outputURL);route = generateAfterAnalysis ? .editor : .export;return
        }
        // Preserve the previous file until a replacement has successfully completed.
        manualSelection = false
        selectedTool = nil
        let previousPhase = phase
        let regenerate=needsRegeneration || generateAfterAnalysis
        let stopAfterAnalysis=analysisOnly
        generatingVideo=regenerate
        generationAnalysisWeight=regenerate && !hasCompletedTracking ? 0.6 : 0
        generationRedactionWeight=regenerate && project.settings.redaction.enabled && project.redactionPlan?.covers(project) != true ? 0.15 : 0
        let checkpoint: Double
        if regenerate {checkpoint=0}
        else if case .blocked(let issue) = phase { checkpoint = issue.checkpoint }
        else if case .paused(let progress) = phase { checkpoint = progress }
        else { checkpoint = 0 }
        targetExplicitlySelected = false
        if project.isDemo { runDemo(from: checkpoint); return }
        guard let url = store.sourceURL(for: project) else { errorMessage = MediaError.missingSource.localizedDescription; return }
        processingMessage=nil
        phase = .processing(progress: checkpoint)
        let previousTask=processingTask
        previousTask?.cancel()
        let id=UUID();operationID=id
        let pipeline=self.pipeline,exporter=self.exporter
        let cached=hasCompletedTracking ? targetSamples : nil
        processingTask=Task { [weak self] in
            // Finish cancellation before touching a checkpoint again; actor methods are reentrant.
            await previousTask?.value
            guard let self,self.isCurrent(id,projectID:project.id),!Task.isCancelled else { return }
            do {
                if previousPhase == .editing { await pipeline.discard(projectID:project.id) }
                try Task.checkCancellation()
                let result:TrackingResult
                if let cached { result = .init(samples:cached,issue:nil) }
                else { result=try await pipeline.analyze(source:url,project:project) { [weak self] update in
                    await self?.receive(update,operationID:id,projectID:project.id,regenerating:regenerate)
                } }
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else { return }
                self.targetSamples=result.samples
                #if DEBUG
                let reuse:[String:Any] = ["projectID":project.id.uuidString,"reused":cached != nil,"sampleCount":result.samples.count,"start":project.settings.start,"end":project.settings.end]
                if let data=try? JSONSerialization.data(withJSONObject:reuse) {try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-last-cache.json"),options:.atomic)}
                #endif
                if !result.reviewTimes.isEmpty {
                    let people=await pipeline.cachedPeople(source:url)
                    guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                    self.analysisReview=AnalysisReview(frames:result.reviewTimes.sorted().map {.init(time:$0)},samples:result.samples,people:people)
                    self.analyzedPeople=people;self.processingPreview=nil;self.generatingVideo=false
                    self.phase = .blocked(result.issue ?? .init(time:result.reviewTimes[0],message:"请逐一确认同一主角",checkpoint:1))
                    self.persist();self.selectReviewFrame(at:result.reviewTimes[0]);return
                }
                if let issue=result.issue {
                    self.processingPreview=nil;self.phase = .blocked(issue);self.seek(to:issue.time)
                    if issue.requiresManualSelection {self.beginManualSelection()}
                    return
                }
                if cached == nil {
                    await self.persistenceTask?.value
                    guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                    do {let people=await pipeline.cachedPeople(source:url);try await self.store.saveTrajectory(project:project,samples:result.samples,people:people)}
                    catch {if !Task.isCancelled,self.isCurrent(id,projectID:project.id) {self.errorMessage="分析完成，但结果缓存未能保存：\(error.localizedDescription)"}}
                    guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                }
                self.analyzedPeople=await pipeline.cachedPeople(source:url)
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                self.hasCompletedTracking=true
                if stopAfterAnalysis {
                    self.analysisOnly=false;self.generatingVideo=false
                    self.processingPreview=nil;self.phase = .editing;self.route = .editor
                    self.currentTime=project.settings.start;self.seek(to:project.settings.start);self.persist()
                    return
                }
                var renderProject=project
                let conflicts=RedactionPolicy.conflicts(project:project,samples:result.samples)
                if !conflicts.isEmpty {
                    renderProject.settings.redaction.subjects.removeAll {conflicts.contains($0.id)}
                    renderProject.redactionPlan=nil
                    self.project?.settings.redaction=renderProject.settings.redaction;self.project?.redactionPlan=nil
                }
                if renderProject.settings.redaction.enabled && renderProject.redactionPlan?.covers(renderProject) != true {
                    let masks=try await pipeline.redactions(source:url,project:renderProject,samples:result.samples) { [weak self] progress in
                        await self?.receiveRedactionProgress(progress,id:id,projectID:project.id,regenerating:regenerate)
                    }
                    guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                    if let issue=masks.issue {
                        self.redactionIssue=issue;self.targetExplicitlySelected=false
                        self.processingPreview=nil
                        self.phase = .blocked(.init(time:issue.time,message:issue.message,checkpoint:0.9))
                        self.seek(to:issue.time);return
                    }
                    guard let plan=masks.plan,plan.covers(renderProject) else {throw RedactionError.incomplete}
                    renderProject.redactionPlan=plan;self.project?.redactionPlan=plan
                    self.redactionIssue=nil;self.refreshRedactionPreview()
                }
                self.project?.progressState="已分析 · 可预览"
                self.persist()
                if regenerate {
                    self.processingMessage="正在按新配置生成视频"
                    let generated=try await exporter.exportMovingCrop(source:url,project:renderProject,samples:result.samples) { [weak self] progress in
                        await self?.receiveRegenerationProgress(progress,id:id,projectID:project.id)
                    }
                    defer {try? FileManager.default.removeItem(at:generated)}
                    guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                    await self.persistenceTask?.value
                    let output=try await self.store.saveOutput(project:renderProject,url:generated)
                    guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                    self.outputURL=output;self.outputSettings=renderProject.settings;self.savedToPhotos=false
                    self.lastGeneratedRecipe=GenerationRecipe(renderProject)
                    self.exportPoster=nil;self.previewPlayer=AVPlayer(url:output)
                    self.generatingVideo=false;self.phase = .completed(output);self.route = self.generateAfterAnalysis ? .editor : .export;self.persist();return
                }
                let item=try await exporter.preview(source:url,project:renderProject,samples:result.samples)
                let poster=await self.poster(for:item)
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else { return }
                self.exportPoster=poster;self.previewPlayer=AVPlayer(playerItem:item)
                self.lastGeneratedRecipe=GenerationRecipe(renderProject)
                self.phase = .readyToExport;self.route = .export
            } catch {
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else { return }
                self.generatingVideo=false
                if stopAfterAnalysis,case TrackingError.noTarget = error {
                    self.phase = .blocked(.init(time:self.currentTime,message:"未识别到主角，请点击人物或手动框选",checkpoint:checkpoint))
                    self.targetExplicitlySelected=false;self.seek(to:self.currentTime)
                } else {self.phase=previousPhase;self.errorMessage=error.localizedDescription}
            }
        }
    }

    private func runDemo(from checkpoint: Double) {
        let previousTask=processingTask
        previousTask?.cancel()
        let id=UUID();operationID=id
        let projectID=project?.id
        phase = .processing(progress: checkpoint)
        processingTask = Task { [weak self] in
            await previousTask?.value
            var progress = checkpoint
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                guard let self,self.operationID==id,self.project?.id==projectID,case .processing = self.phase,let project=self.project else { return }
                progress = min(1, progress + 0.018)
                self.currentTime = project.settings.start + (project.settings.end - project.settings.start) * progress
                if !self.hasCompletedTracking,checkpoint < 0.56, progress >= 0.56 {
                    self.currentTime = min(22.4, project.settings.end)
                    self.phase = .blocked(TrackingIssue(time: self.currentTime, message: "交叉后人物匹配不确定", checkpoint: progress))
                    self.targetExplicitlySelected = false
                    return
                }
                self.phase = .processing(progress: progress)
                if progress >= 1 {
                    if self.analysisOnly {
                        self.targetSamples=[.init(time:project.settings.start,body:project.target!),.init(time:project.settings.end,body:project.target!)]
                        self.hasCompletedTracking=true;self.analysisOnly=false;self.phase = .editing
                    } else if self.generateAfterAnalysis {self.generatingVideo=false;self.phase = .completed(nil)}
                    else {self.phase = .readyToExport;self.route = .export}
                    return
                }
            }
        }
    }
    func cancelGeneration() {
        guard generatingVideo else {return}
        backToEditor();generatingVideo=false;persist()
    }
    func pause() {
        guard case .processing(let progress) = phase else { return }
        operationID=UUID();processingTask?.cancel()
        phase = .paused(progress: progress)
    }
    func reselectAnalysisTarget() {
        guard !generatingVideo else {return}
        switch phase {case .processing,.paused:break;default:return}
        cancelTasks()
        project?.target=nil;project?.redactionPlan=nil
        project?.settings.compositionAnchor=nil
        compositionCrop=nil;compositionAutomatic=nil
        targetExplicitlySelected=false;manualSelection=false;selectedTool=nil
        outputURL=nil;outputSettings=nil;lastGeneratedRecipe=nil;savedToPhotos=false
        processingMessage=nil;errorMessage=nil
        phase = .editing;route = .editor
        seek(to:project?.settings.start ?? 0)
        persist()
    }
    func returnToEditingFromPause() {
        guard case .paused = phase else {return}
        // Wait for cancellation through the existing task barrier. Partial tracking is discarded;
        // completed analysis remains reusable when only rendering settings change.
        backToEditor()
        persist()
    }
    func resume() {
        guard case .paused(let progress) = phase else { return }
        if isDemo { runDemo(from: progress) }
        else { confirmProcessing() }
    }
    func togglePreview() {
        guard phase == .editing else {return}
        if let project,hasCompletedTracking,project.settings.redaction.enabled,project.redactionPlan?.covers(project) != true {
            detectionNotice="确认处理后可播放完整打码效果";return
        }
        if compositionEditing { toggleCompositionPlayback();return }
        guard controlsEnabled, !manualSelection else { return }
        if isPlaying { pausePreview(); return }
        guard let project else { return }
        if currentTime >= project.settings.end-0.05 { seek(to:project.settings.start) }
        detectionID=UUID();detectionTask?.cancel();detecting=false;observations=[]
        isPlaying=true; player?.play(); selectedTool=nil
        previewTask=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
                guard let self, self.isPlaying, let project=self.project else { return }
                if self.isDemo { self.currentTime += 0.1 }
                else if let time=self.player?.currentTime().seconds, time.isFinite { self.currentTime=time }
                if self.currentTime >= project.settings.end { self.pausePreview(); return }
            }
        }
    }
    func pausePreview(refresh:Bool = true) {
        if compositionEditing {
            let wasPlaying=isPlaying
            isPlaying=false;previewTask?.cancel();previewPlayer?.pause();player?.pause()
            if wasPlaying,let project,hasCompletedTracking,let time=previewPlayer?.currentTime().seconds,time.isFinite {
                currentTime=min(project.settings.end,max(project.settings.start,project.settings.start+time))
                compositionCrop=CropPlan.rect(at:currentTime,in:compositionFrames)
                player?.seek(to:CMTime(seconds:currentTime,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
            }
            return
        }
        let wasPlaying=isPlaying
        isPlaying=false; previewTask?.cancel(); player?.pause()
        if wasPlaying,!isDemo,let project,let time=player?.currentTime().seconds,time.isFinite {
            currentTime=min(project.settings.end,max(project.settings.start,time))
            if abs(time-currentTime)>0.001 {
                player?.seek(to:CMTime(seconds:currentTime,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
            }
        }
        if refresh && wasPlaying && !isDemo { detectPeople() }
    }
    func seek(to time: Double) {
        guard let project else { return }
        if isReviewing {selectReviewFrame(at:time);return}
        if compositionEditing {
            guard hasCompletedTracking,time.isFinite else { return }
            currentTime=min(project.settings.end,max(project.settings.start,time))
            compositionCrop=CropPlan.rect(at:currentTime,in:compositionFrames)
            player?.seek(to:CMTime(seconds:currentTime,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
            previewPlayer?.seek(to:CMTime(seconds:currentTime-project.settings.start,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
            return
        }
        if controlsEnabled { processingPreview=nil }
        guard time.isFinite else { return }
        currentTime=min(project.settings.end,max(project.settings.start,time))
        player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if controlsEnabled, !isDemo { detectPeople() }
    }
    func scrub(to time:Double, within bounds:ClosedRange<Double>? = nil, sourceOnly:Bool = false) {
        guard phase == .editing else {return}
        if compositionEditing && !sourceOnly {seek(to:time);return}
        guard controlsEnabled,let project,time.isFinite else {return}
        pausePreview(refresh:false)
        detectionID=UUID();detectionTask?.cancel();detecting=false;observations=[];detectionNotice=nil
        let lower = max(0, bounds?.lowerBound ?? project.settings.start)
        let upper = min(project.metadata.duration, bounds?.upperBound ?? project.settings.end)
        currentTime=min(upper,max(lower,time))
        player?.seek(to:CMTime(seconds:currentTime,preferredTimescale:60000),toleranceBefore:CMTime(seconds:0.1,preferredTimescale:600),toleranceAfter:CMTime(seconds:0.1,preferredTimescale:600))
    }
    func finishScrubbing(within bounds:ClosedRange<Double>? = nil) {
        guard !compositionEditing else {return}
        if let bounds, let project, controlsEnabled {
            currentTime = min(project.metadata.duration, min(bounds.upperBound, max(bounds.lowerBound, currentTime)))
            player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            if !isDemo { detectPeople() }
        } else { seek(to:currentTime) }
    }
    func updateRange(start: Double? = nil, end: Double? = nil, previewTime: Double? = nil) {
        guard settingsEnabled,!compositionAdjusting,
              start?.isFinite != false,end?.isFinite != false,previewTime?.isFinite != false,
              let project else { return }
        pausePreview(refresh:false)
        let wasAnalyzed=hasCompletedTracking
        let minimum = min(0.5, project.metadata.duration)
        var settings = project.settings
        if let start { settings.start = min(max(0, start), max(0, min(project.metadata.duration, end ?? settings.end) - minimum)) }
        if let end { settings.end = min(project.metadata.duration, max(settings.start + minimum, end)) }
        self.project?.settings = settings
        if let selected=self.project {
            if selected.isDemo {
                hasCompletedTracking = targetSamples.first.map {$0.time<=settings.start} == true
                    && targetSamples.last.map {$0.time>=settings.end} == true
            } else {
                hasCompletedTracking = !targetSamples.isEmpty && (try? VideoExporter.validateTrajectory(targetSamples,project:selected)) != nil
            }
        }
        if !hasCompletedTracking,let selected=self.project,selected.target != nil,
           selected.targetTime<selected.settings.start || selected.targetTime>selected.settings.end {
            self.project?.target=nil;self.project?.settings.compositionAnchor=nil;targetExplicitlySelected=false
        }
        if !hasCompletedTracking,let anchor=self.project?.settings.compositionAnchor,let settings=self.project?.settings,
           anchor.time<settings.start || anchor.time>settings.end {self.project?.settings.compositionAnchor=nil}
        let updated = self.project!.settings
        let time = previewTime ?? (end != nil ? updated.end : updated.start)
        if wasAnalyzed && !hasCompletedTracking {
            if redactionEditing {finishRedaction(commit:true)}
            if compositionEditing {finishComposition(commit:true,refreshDetections:false)}
            previewPlayer?.pause();previewPlayer=nil
            targetExplicitlySelected=self.project?.target != nil
            seek(to:time);persist();return
        }
        if compositionEditing {
            // Timeline edits are global; cancelling a composition only rolls back its viewport.
            compositionSnapshot?.start = updated.start
            compositionSnapshot?.end = updated.end
            if let anchor = compositionSnapshot?.compositionAnchor,
               anchor.time < updated.start || anchor.time > updated.end {
                compositionSnapshot?.compositionAnchor = nil
            }
            if self.project?.target == nil {
                compositionSnapshot = nil
                finishComposition(commit: false, refreshDetections: false)
                seek(to: time)
            } else {
                let reference = hasCompletedTracking ? time : (updated.compositionAnchor?.time ?? self.project!.targetTime)
                currentTime = min(updated.end, max(updated.start, reference))
                player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                refreshComposition()
            }
        } else { seek(to: time) }
        persist()
    }
    func persist() {
        guard var project,!project.isDemo else { return }
        switch phase {
        case .completed:project.progressState=savedToPhotos ? "已保存到相册" : "已生成 · 待保存"
        case .blocked:project.progressState="待纠正"
        case .processing,.paused:project.progressState="处理中断"
        default:project.progressState=hasCompletedTracking ? "已分析 · 可预览" : (project.target == nil ? "待选人" : "待处理")
        }
        project.updatedAt=Date();self.project=project
        let review=analysisReview
        let previous=persistenceTask
        persistenceTask=Task {
            await previous?.value
            do {
                try await store.save(project)
                if let review {try await store.saveReview(review,project:project)}
                else {try await store.removeReview(project.id)}
                await loadProjects()
            }
            catch { errorMessage="自动保存失败：\(error.localizedDescription)" }
        }
    }
    func delete(_ project:VideoProject) async {
        if self.project?.id==project.id {
            cancelTasks();self.project=nil;route = .home
        }
        let previous=persistenceTask
        let task=Task {
            await previous?.value
            do { try await store.remove(project);await loadProjects() }
            catch { errorMessage=error.localizedDescription }
        }
        persistenceTask=task
        await task.value
    }
    func goHome() {
        if compositionEditing {finishComposition(commit:true,refreshDetections:false)}
        persist()
        cancelTasks()
        route = .home
    }
    func backToEditor() {
        let preserve=hasCompletedTracking
        cancelTasks(preserveAnalysis:preserve);route = .editor;phase = .editing
        seek(to:project?.targetTime ?? currentTime)
    }
    func export() {
        guard phase == .readyToExport, phase.issue == nil else { return }
        if isDemo { phase = .completed(nil); return }
        guard let project, let url = store.sourceURL(for: project), !targetSamples.isEmpty else { return }
        let previousTask=processingTask
        previousTask?.cancel()
        let id=UUID();operationID=id
        let samples=targetSamples,exporter=self.exporter
        previewPlayer?.pause()
        previewPlayer?.replaceCurrentItem(with:nil);previewPlayer=nil
        exportProgress=0;cancellingExport=false
        phase = .exporting
        processingTask=Task { [weak self] in
            await previousTask?.value
            guard let self,!Task.isCancelled,self.isCurrent(id,projectID:project.id) else { return }
            do {
                let renderedOutput=try await exporter.exportMovingCrop(source:url,project:project,samples:samples) { [weak self] progress in
                    await self?.receiveExportProgress(progress,id:id,projectID:project.id)
                }
                defer {try? FileManager.default.removeItem(at:renderedOutput)}
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                let output=try await self.store.saveOutput(project:project,url:renderedOutput)
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
                self.outputURL=output;self.outputSettings=project.settings;self.lastGeneratedRecipe=GenerationRecipe(project);self.exportPoster=nil;self.exportProgress=1
                #if DEBUG
                let temporary=FileManager.default.temporaryDirectory
                try? JSONEncoder().encode(project).write(to:temporary.appendingPathComponent("FancamDuck-export-project.json"),options:.atomic)
                try? JSONEncoder().encode(samples).write(to:temporary.appendingPathComponent("FancamDuck-export-trajectory.json"),options:.atomic)
                try? output.lastPathComponent.write(to:temporary.appendingPathComponent("FancamDuck-export-name.txt"),atomically:true,encoding:.utf8)
                try? output.path.write(to:temporary.appendingPathComponent("FancamDuck-export-path.txt"),atomically:true,encoding:.utf8)
                #endif
                self.previewPlayer=AVPlayer(url:output);self.phase = .completed(output);self.persist()
            } catch {
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else { return }
                let message=error.localizedDescription
                let item=try? await exporter.preview(source:url,project:project,samples:samples)
                let poster:CGImage?
                if let item {poster=await self.poster(for:item)} else {poster=nil}
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else { return }
                self.previewPlayer=item.map {AVPlayer(playerItem:$0)};self.exportPoster=poster
                self.phase = .readyToExport;self.errorMessage=message
            }
        }
    }
    private func poster(for item:AVPlayerItem) async -> CGImage? {
        let generator=AVAssetImageGenerator(asset:item.asset)
        generator.videoComposition=item.videoComposition;generator.appliesPreferredTrackTransform=true
        generator.maximumSize = .init(width:360,height:640)
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at:.zero).image
    }
    private func receiveExportProgress(_ progress:Double,id:UUID,projectID:UUID) {
        guard progress.isFinite,isCurrent(id,projectID:projectID),phase == .exporting,!cancellingExport else {return}
        exportProgress=max(exportProgress,min(0.99,max(0,progress)))
    }
    func cancelExport() {
        guard phase == .exporting,!cancellingExport,let project,let source=store.sourceURL(for:project) else {return}
        let previous=processingTask;previous?.cancel()
        let id=UUID();operationID=id;cancellingExport=true
        let samples=targetSamples,exporter=self.exporter
        processingTask=Task { [weak self] in
            await previous?.value
            guard let self,!Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
            let item=try? await exporter.preview(source:source,project:project,samples:samples)
            let poster:CGImage?
            if let item {poster=await self.poster(for:item)} else {poster=nil}
            guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else {return}
            self.previewPlayer=item.map {AVPlayer(playerItem:$0)};self.exportPoster=poster
            self.exportProgress=0;self.cancellingExport=false;self.phase = .readyToExport
        }
    }
    func saveVideo() async {
        guard !savingToPhotos,!savedToPhotos,let outputURL else { return }
        savingToPhotos=true
        let id=operationID
        defer {if operationID==id {savingToPhotos=false}}
        do {
            try await photoSaver.saveToPhotos(url:outputURL)
            if operationID==id,self.outputURL==outputURL {
                savedToPhotos=true
                if let project {try await store.markOutputSaved(project:project,url:outputURL);persist()}
            }
        } catch { if operationID==id { errorMessage=error.localizedDescription } }
    }
    private func isCurrent(_ id:UUID,projectID:UUID) -> Bool { operationID==id && project?.id==projectID }
    private func receive(_ update:TrackingUpdate,operationID id:UUID,projectID:UUID,regenerating:Bool=false) {
        guard isCurrent(id,projectID:projectID),case .processing = phase else { return }
        processingMessage=update.message
        if let preview=update.preview {
            trackedSample=update.sample;currentTime=update.sample.time;processingPreview=preview
        } else if processingPreview == nil {
            trackedSample=update.sample;currentTime=update.sample.time
        }
        phase = .processing(progress:max(phase.progress,update.progress * (regenerating ? generationAnalysisWeight : analysisOnly ? 1 : project?.settings.redaction.enabled == true ? 0.85 : 1)))
    }
    func detectPeople(region: NormalizedRect? = nil) {
        if isReviewing {selectReviewFrame(at:currentTime);return}
        guard controlsEnabled,!restoringTracking,let project,let source=store.sourceURL(for:project) else { return }
        if hasCompletedTracking,!analyzedPeople.isEmpty,region == nil {
            detectionID=UUID();detectionTask?.cancel();detecting=false;detectionNotice=nil
            let key=Int((currentTime*10000).rounded())
            if let nearest=analyzedPeople.keys.min(by:{abs($0-key)<abs($1-key)}) {observations=analyzedPeople[nearest]?.primary ?? []}
            refreshRedactionPreview();return
        }
        let id=UUID();detectionID=id
        detectionTask?.cancel();observations=[];detecting=true;detectionNotice=nil
        let time = currentTime
        detectionTask = Task {
            defer {
                if detectionID==id,self.project?.id==project.id {detecting=false}
            }
            do {
                try await Task.sleep(for:.milliseconds(120))
                let found = try await pipeline.detections(source: source, time: time, region: region)
                guard !Task.isCancelled,detectionID==id,controlsEnabled,self.project?.id==project.id,abs(currentTime-time)<0.001 else { return }
                observations = found; detecting = false; manualSelection = false
                refreshRedactionPreview()
                if abs(project.targetTime-time)<0.001,let target=project.target {
                    selectionObservation=found.filter {$0.body.iou(target)>0.7}.max {$0.body.iou(target)<$1.body.iou(target)}
                }
                if found.isEmpty { detectionNotice = "未识别到人物 · 请换帧或手动框选人物" }
            } catch {
                guard !Task.isCancelled,detectionID==id,controlsEnabled,self.project?.id==project.id else { return }
                detecting=false;errorMessage=error.localizedDescription
            }
        }
    }
    func beginManualSelection() {
        guard controlsEnabled,!restoringTracking else {return}
        pausePreview(refresh:false)
        detectionID=UUID();detectionTask?.cancel();detecting=false
        detectionNotice=nil;manualSelection=true
    }
    @discardableResult func finishManualBox(_ box: NormalizedRect) -> Bool {
        guard controlsEnabled else {return false}
        guard box.isValid,box.width>0.015,box.height>0.03 else {
            detectionNotice="选区太小，请扩大人物框";return false
        }
        if isReviewing {
            reviewSelection=box;manualSelection=false
            confirmReviewFrame();return true
        }
        if let issue=redactionIssue {
            guard project?.settings.redaction.subjects.contains(where:{$0.id==issue.subjectID}) == true else {return false}
            guard canRedactPerson(box) else {detectionNotice="主角不参与打码";return false}
        }
        // The user's rectangle is the explicit target anchor, not another detector request.
        detectionID=UUID();detectionTask?.cancel();detecting=false
        observations=[];detectionNotice=nil;selectionObservation=nil
        selectTarget(box)
        let accepted:Bool
        if let issue=redactionIssue {
            accepted=project?.settings.redaction.subjects.first(where:{$0.id==issue.subjectID})?.anchors.contains(where:{abs($0.time-currentTime)<0.001 && $0.body==box}) == true
        } else {accepted=targetExplicitlySelected && project?.target==box}
        if accepted {manualSelection=false}
        return accepted
    }
    func suspend() { pause();pausePreview(refresh:false);previewPlayer?.pause();persist() }
    private func cancelTasks(preserveAnalysis:Bool=false) {
        reviewID=UUID();reviewTasks.values.forEach {$0.cancel()};reviewTasks=[:]
        analysisReview=nil;reviewSelection=nil
        if redactionEditing { finishRedaction(commit:true) }
        generatingVideo=false;analysisOnly=false;generateAfterAnalysis=false
        redactionIssue=nil;redactionPreviewID=UUID();redactionPreviewTask?.cancel();redactionImageID=UUID();importingRedactionImage=false
        if compositionEditing { finishComposition(commit:true,refreshDetections:false) }
        restorationID=UUID();restorationTask?.cancel();restoringTracking=false;savingToPhotos=false;detectionNotice=nil;cancellingExport=false;exportProgress=0
        compositionTask?.cancel();compositionID=UUID();compositionBusy=false;compositionFrames=[];compositionAutomaticFrames=[]
        pausePreview(refresh:false);operationID=UUID();detectionID=UUID();importID=UUID();importing=false
        detectionTask?.cancel();detecting=false;observations=[]
        processingPreview=nil;trackedSample=nil
        if !preserveAnalysis {targetSamples=[];hasCompletedTracking=false;selectionObservation=nil;analyzedPeople=[:]}
        previewPlayer?.pause();previewPlayer=nil;exportPoster=nil
        thumbnailTask?.cancel();player?.pause()
        let previous=processingTask,projectID=project?.id,pipeline=self.pipeline
        previous?.cancel()
        // Queue disposal behind the old task. New work waits for this barrier, even for the same project.
        processingTask=Task {
            await previous?.value
            if let projectID { await pipeline.discard(projectID:projectID) }
        }
    }
}

enum EditorTool: String, CaseIterable {
    case resolution, size, speed, position
}

extension AppModel {
    private var compositionSamples:[TargetSample] {
        if hasCompletedTracking { return targetSamples }
        guard let project,let target=project.target else { return [] }
        if let anchor=project.settings.compositionAnchor,anchor.isValid {
            return [.init(time:anchor.time,body:anchor.referenceBody ?? target)]
        }
        let observation=selectionObservation
        return [.init(time:project.targetTime,body:target,protection:observation.flatMap {$0.body.iou(target)>0.7 ? $0.protectionBody : nil},focusX:observation?.focusX)]
    }
    func beginComposition() {
        guard settingsEnabled,project?.target != nil,!compositionEditing else { return }
        // Composition uses the selected anchor, not the pending frame's candidates.
        detectionID=UUID();detectionTask?.cancel();detecting=false
        pausePreview(refresh:false);selectedTool=nil;manualSelection=false
        compositionSnapshot=project?.settings;compositionUndo=[];compositionEditing=true;compositionNotice=nil
        compositionCrop=hasCompletedTracking ? CropPlan.rect(at:currentTime,in:compositionFrames) : nil;compositionAutomatic=nil;compositionFrames=[];compositionAutomaticFrames=[];compositionAutomaticSettings=nil
        if !hasCompletedTracking { currentTime=project?.settings.compositionAnchor?.time ?? project?.targetTime ?? currentTime }
        player?.seek(to:CMTime(seconds:currentTime,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
        refreshComposition()
    }
    func finishComposition(commit:Bool,refreshDetections:Bool=true) {
        guard compositionEditing else { return }
        pausePreview(refresh:false)
        if commit,!hasCompletedTracking,project?.settings.compositionAnchor == nil,let crop=compositionCrop {saveCompositionAnchor(crop)}
        if !commit,let snapshot=compositionSnapshot {project?.settings=snapshot}
        compositionTask?.cancel();compositionID=UUID();compositionBusy=false;compositionAdjusting=false
        compositionEditing=false;compositionSnapshot=nil;compositionUndo=[];compositionNotice=nil
        persist()
        if refreshDetections,!isDemo,let project,abs(currentTime-project.targetTime)>0.001 {detectPeople()}
    }
    private func refreshComposition() {
        guard compositionEditing,let project else { return }
        compositionTask?.cancel();let id=UUID();compositionID=id
        let samples=compositionSamples,settings=project.settings,source=project.metadata.size
        var automatic=settings;automatic.compositionScale=1;automatic.compositionX=0;automatic.compositionY=0;automatic.compositionAnchor=nil
        let cachedAutomatic=compositionAutomaticSettings==automatic ? compositionAutomaticFrames : []
        compositionBusy=true
        compositionTask=Task { [weak self] in
            let computed=await Task.detached(priority:.userInitiated) {
                (CropPlan.renderFrames(CropPlan.make(samples:samples,source:source,settings:settings),frameRate:project.metadata.frameRate,preserving:settings.compositionAnchor?.time),
                 cachedAutomatic.isEmpty ? CropPlan.renderFrames(CropPlan.make(samples:samples,source:source,settings:automatic),frameRate:project.metadata.frameRate) : cachedAutomatic)
            }.value
            guard let self,!Task.isCancelled,self.compositionEditing,self.compositionID==id,self.project?.id==project.id else { return }
            self.compositionFrames=computed.0;self.compositionAutomaticFrames=computed.1;self.compositionAutomaticSettings=automatic
            self.compositionCrop=CropPlan.rect(at:self.currentTime,in:computed.0)
            self.compositionAutomatic=CropPlan.rect(at:self.currentTime,in:computed.1)

            do {
                if self.hasCompletedTracking,project.settings.redaction.enabled,project.redactionPlan?.covers(project) != true {
                    // Camera editing remains available before the new masks are analyzed. Never
                    // reuse a moving preview with an older (or missing) privacy plan.
                    self.previewPlayer?.pause();self.previewPlayer=nil
                    self.compositionNotice="打码设置已更改，确认处理后可播放"
                } else if self.hasCompletedTracking,let url=self.store.sourceURL(for:project) {
                    let item=try await self.exporter.preview(source:url,project:project,samples:samples)
                    guard !Task.isCancelled,self.compositionEditing,self.compositionID==id,self.project?.id==project.id else { return }
                    if let player=self.previewPlayer {player.replaceCurrentItem(with:item)}
                    else {self.previewPlayer=AVPlayer(playerItem:item)}
                    self.previewPlayer?.seek(to:CMTime(seconds:self.currentTime-settings.start,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero,completionHandler:{_ in})
                }
                self.compositionBusy=false
            } catch {
                guard self.compositionID==id,!Task.isCancelled else {return}
                self.compositionBusy=false;self.errorMessage=error.localizedDescription
            }
        }
    }
    func beginCompositionGesture() {
        guard compositionEditing,settingsEnabled,compositionCrop != nil,compositionAutomatic != nil else {return}
        pausePreview(refresh:false)
        // A new edit supersedes the pending calculation instead of locking the canvas.
        compositionTask?.cancel();compositionID=UUID();compositionBusy=false
        compositionGestureSettings=project?.settings;compositionAdjusting=true;compositionNotice=nil
    }
    func applyCompositionCrop(_ proposed:CGRect) {
        guard compositionEditing,let project,let automatic=compositionAutomatic,proposed.width.isFinite,proposed.height.isFinite,proposed.height>0 else {return}
        let samples=compositionSamples
        guard let reference=samples.min(by:{abs($0.time-currentTime)<abs($1.time-currentTime)}) else {return}
        let crop=CompositionGeometry.constrain(proposed,source:project.metadata.size,samples:samples,reference:reference,protect:false,aspect:project.settings.aspectRatio)
        compositionCrop=crop
        self.project?.settings.compositionScale=automatic.height/crop.height
        self.project?.settings.compositionX=(automatic.midX-crop.midX)/crop.width
        self.project?.settings.compositionY=(automatic.midY-crop.midY)/crop.height
        saveCompositionAnchor(crop)
        let constrained=abs(crop.height-proposed.height)>0.5 || abs(crop.minX-proposed.minX)>0.5 || abs(crop.minY-proposed.minY)>0.5
        compositionNotice=constrained ? "已达到画面边界" : nil
    }
    private func saveCompositionAnchor(_ crop:CGRect) {
        guard let project else {return}
        let size=project.metadata.size
        let body=compositionSamples.min {abs($0.time-currentTime)<abs($1.time-currentTime)}?.body
        self.project?.settings.compositionAnchor = .init(time:currentTime,crop:.init(x:crop.minX/size.width,y:crop.minY/size.height,width:crop.width/size.width,height:crop.height/size.height),referenceBody:body)
        #if DEBUG
        if let project=self.project,!project.isDemo,let data=try? JSONEncoder().encode(project) {
            try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-selected-\(project.id).json"),options:.atomic)
            try? data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("FancamDuck-selected-composition.json"),options:.atomic)
        }
        #endif
    }
    func endCompositionGesture(cancelled:Bool=false) {
        guard compositionEditing else {return}
        if let before=compositionGestureSettings {
            if cancelled {project?.settings=before}
            else if before != project?.settings {compositionUndo.append(before);if compositionUndo.count>20 {compositionUndo.removeFirst()}}
        }
        compositionGestureSettings=nil;compositionAdjusting=false;refreshComposition();persist()
    }
    func compositionZoom(_ factor:Double) {
        guard let crop=compositionCrop else {return}
        beginCompositionGesture()
        guard compositionAdjusting else {return}
        applyCompositionCrop(CompositionGeometry.transformed(crop,scale:factor,translation:.zero,anchor:.init(x:0.5,y:0.5),viewport:.init(width:1,height:1)))
        endCompositionGesture()
    }
    func compositionMove(x:Double,y:Double) {
        guard let crop=compositionCrop else {return}
        beginCompositionGesture();guard compositionAdjusting else {return};applyCompositionCrop(crop.offsetBy(dx:-x*crop.width,dy:-y*crop.height));endCompositionGesture()
    }
    func setCompositionAspect(_ aspect: OutputAspectRatio) {
        // A newer selection supersedes the pending preview through compositionID/cancellation.
        guard compositionEditing,!compositionAdjusting,
              let project,project.settings.aspectRatio != aspect else {return}
        pausePreview(refresh:false)
        compositionUndo.append(project.settings)
        self.project?.settings.aspectRatio=aspect
        let sizes=OutputResolution.available(for:project.metadata,aspect:aspect)
        // Preserve the selected quality budget where possible, without upscaling the source.
        self.project?.settings.resolution=sizes.last(where: {max($0.width,$0.height)<=max(project.settings.resolution.width,project.settings.resolution.height)}) ?? sizes.first ?? project.settings.resolution
        if let automatic=compositionAutomatic {
            compositionAutomatic=CompositionGeometry.reframed(automatic,source:project.metadata.size,aspect:aspect)
        }
        if let crop=compositionCrop {
            let reframed=CompositionGeometry.reframed(crop,source:project.metadata.size,aspect:aspect)
            compositionCrop=reframed
            saveCompositionAnchor(reframed)
        }
        refreshComposition();persist()
    }
    func centerComposition(horizontal:Bool) {
        guard compositionEditing,!compositionAdjusting,
              let project,let crop=compositionCrop,
              let reference=compositionSamples.min(by:{abs($0.time-currentTime)<abs($1.time-currentTime)}) else {return}
        beginCompositionGesture()
        guard compositionAdjusting else {return}
        // Center the dancer on the chosen axis; retain the other axis and current zoom.
        let x=horizontal ? reference.body.center.x*project.metadata.width-crop.width/2 : crop.minX
        let y=horizontal ? crop.minY : reference.body.center.y*project.metadata.height-crop.height/2
        applyCompositionCrop(CGRect(x:x,y:y,width:crop.width,height:crop.height))
        endCompositionGesture()
    }
    func resetComposition(centerOnly:Bool=false) {
        guard compositionEditing,!compositionAdjusting,let currentProject=project else {return}
        let settings=currentProject.settings
        compositionUndo.append(settings);project?.settings.compositionX=0;project?.settings.compositionY=0
        project?.settings.horizontalOffset=0
        if centerOnly,let automatic=compositionAutomatic,let crop=compositionCrop {
            saveCompositionAnchor(CGRect(x:min(currentProject.metadata.width-crop.width,max(0,automatic.midX-crop.width/2)),y:min(currentProject.metadata.height-crop.height,max(0,automatic.midY-crop.height/2)),width:crop.width,height:crop.height))
        } else {project?.settings.compositionAnchor=nil;project?.settings.compositionScale=1;project?.settings.personHeight=0.75}
        refreshComposition()
    }
    func undoComposition() {
        guard compositionEditing,!compositionAdjusting,let before=compositionUndo.popLast() else {return}
        project?.settings=before;refreshComposition()
    }
    func setFollowSpeed(_ speed: EditSettings.FollowSpeed) {
        guard settingsEnabled, !compositionAdjusting,
              project?.settings.followSpeed != speed else { return }
        pausePreview(refresh: false)
        project?.settings.followSpeed = speed
        if compositionEditing { refreshComposition() }
        persist()
    }
    func setFullBodyProtection(_ enabled:Bool) {
        guard project?.settings.protectFullBody != enabled else {return}
        if compositionEditing {toggleCompositionProtection();return}
        project?.settings.protectFullBody=enabled;persist()
    }
    func toggleCompositionProtection() {
        guard compositionEditing,!compositionAdjusting,let settings=project?.settings else {return}
        compositionUndo.append(settings);project?.settings.protectFullBody.toggle()
        if let crop=compositionCrop,let project,let reference=compositionSamples.min(by:{abs($0.time-currentTime)<abs($1.time-currentTime)}) {
            saveCompositionAnchor(CompositionGeometry.constrain(crop,source:project.metadata.size,samples:compositionSamples,reference:reference,protect:project.settings.protectFullBody,aspect:project.settings.aspectRatio))
        }
        refreshComposition()
    }
    private func toggleCompositionPlayback() {
        guard hasCompletedTracking else {return}
        if compositionBusy,let task=compositionTask,let project {
            let id=compositionID,settings=project.settings
            previewTask?.cancel()
            previewTask=Task { [weak self] in
                await task.value
                guard let self,!Task.isCancelled,self.compositionID==id,self.project?.id==project.id,
                      self.project?.settings==settings,self.settingsEnabled,self.compositionEditing,!self.compositionBusy else {return}
                self.toggleCompositionPlayback()
            }
            return
        }
        if isPlaying {pausePreview(refresh:false);return}
        if let project,currentTime>=project.settings.end-0.05 {seek(to:project.settings.start)}
        isPlaying=true;previewPlayer?.play()
        previewTask=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.milliseconds(80))} catch {return}
                guard let self,self.compositionEditing,self.isPlaying,let project=self.project else {return}
                if let time=self.previewPlayer?.currentTime().seconds,time.isFinite {
                    self.currentTime=project.settings.start+time
                    self.compositionCrop=CropPlan.rect(at:self.currentTime,in:self.compositionFrames)
                }
                if self.currentTime>=project.settings.end-0.02 {self.pausePreview(refresh:false);return}
            }
        }
    }
}

extension AppModel {
    func beginRedaction() {
        guard settingsEnabled,let project,project.target != nil,!redactionEditing else {return}
        let retainedComposition=compositionEditing
        pausePreview(refresh:false)
        if !hasCompletedTracking,abs(currentTime-project.targetTime)>0.05 {seek(to:project.targetTime)}
        if hasCompletedTracking {beginComposition()}
        redactionEditing=true;redactionSnapshot=project.settings.redaction;redactionPlanSnapshot=project.redactionPlan
        if !retainedComposition {refreshRedactionPreview()}
    }
    func finishRedaction(commit:Bool,keepComposition:Bool=false) {
        if !commit,let snapshot=redactionSnapshot {project?.settings.redaction=snapshot;project?.redactionPlan=redactionPlanSnapshot}
        redactionImageID=UUID();importingRedactionImage=false
        redactionEditing=false;redactionSnapshot=nil;redactionPlanSnapshot=nil
        if compositionEditing && !keepComposition {finishComposition(commit:true,refreshDetections:false)}
        if !commit {refreshRedactionPreview()}
        persist()
    }
    private func redactionSubject(at box:NormalizedRect) -> UUID? {
        guard let project else {return nil}
        if let plan=project.redactionPlan,plan.covers(project),
           let track=plan.tracks.max(by:{(RedactionPlan.rectangle(at:currentTime,frames:$0.bodies)?.iou(box) ?? 0)<(RedactionPlan.rectangle(at:currentTime,frames:$1.bodies)?.iou(box) ?? 0)}),
           (RedactionPlan.rectangle(at:currentTime,frames:track.bodies)?.iou(box) ?? 0)>0.5 {return track.subjectID}
        return project.settings.redaction.subjects.first {subject in
            subject.anchors.contains {abs($0.time-currentTime)<0.06 && $0.body.iou(box)>0.5}
        }?.id
    }
    var redactionPrimaryBody:NormalizedRect? {
        guard let project else {return nil}
        if isDemo,let target=project.target {
            let index=max(0,min(3,Int(((target.center.x*360-57)/82).rounded())))
            return DemoStage.body(index:index,time:currentTime)
        }
        return RedactionPolicy.primaryBody(project:project,time:currentTime,samples:hasCompletedTracking ? targetSamples : [])
    }
    func canRedactPerson(_ box:NormalizedRect) -> Bool {
        guard let primary=redactionPrimaryBody else {return false}
        return primary.iou(box)<=0.6
    }
    func redactionSelected(_ box:NormalizedRect) -> Bool {redactionSubject(at:box) != nil}
    func toggleRedaction(_ box:NormalizedRect) {
        guard settingsEnabled,box.isValid,let project else {return}
        guard canRedactPerson(box) else {detectionNotice="主角不参与打码";return}
        if let id=redactionSubject(at:box),let index=project.settings.redaction.subjects.firstIndex(where:{$0.id==id}) {
            self.project?.settings.redaction.subjects.remove(at:index)
        } else {
            self.project?.settings.redaction.subjects.append(.init(anchors:[.init(time:currentTime,body:box)]))
        }
        self.project?.redactionPlan=nil;refreshRedactionPreview();persist()
    }
    func setRedactionRegion(_ region:RedactionSettings.Region) {
        guard settingsEnabled,project?.settings.redaction.region != region else {return}
        project?.settings.redaction.region=region;project?.redactionPlan=nil
        if region == .person,project?.settings.redaction.style == .image {project?.settings.redaction.style = .frosted}
        refreshRedactionPreview();persist()
    }
    func setRedactionStrength(_ value:Double) {
        guard settingsEnabled,value.isFinite else {return}
        project?.settings.redaction.strength=min(1,max(0.3,value))
        refreshRedactionPreview();persist()
    }
    func enableAutomaticRedaction() {
        guard settingsEnabled else {return}
        project?.settings.redaction.allOthers=true;project?.settings.redaction.subjects=[];project?.redactionPlan=nil
        refreshRedactionPreview();persist()
    }
    func clearRedactions() {
        guard settingsEnabled else {return}
        project?.settings.redaction.subjects=[];project?.settings.redaction.allOthers=false;project?.redactionPlan=nil
        refreshRedactionPreview();persist()
    }
    private func receiveRedactionProgress(_ progress:Double,id:UUID,projectID:UUID,regenerating:Bool=false) {
        guard isCurrent(id,projectID:projectID),!Task.isCancelled,case .processing = phase else {return}
        processingMessage="正在生成平滑打码轨迹"
        phase = .processing(progress:max(phase.progress,(regenerating ? generationAnalysisWeight : 0.85)+min(1,max(0,progress))*(regenerating ? generationRedactionWeight : 0.14)))
    }
    /// Pause-frame settings preview uses the same GPU compositor. Playback is enabled only after
    /// a complete identity-checked plan exists; fixed seed rectangles are never played as tracking.
    func refreshRedactionPreview() {
        // Rebuild the moving preview only when its mask settings change, not when tabs switch.
        if hasCompletedTracking,compositionEditing,!compositionAdjusting {refreshComposition()}
        redactionPreviewTask?.cancel();let id=UUID();redactionPreviewID=id
        guard let project,!isDemo,!restoringTracking,let item=player?.currentItem else {return}
        guard project.settings.redaction.enabled,(hasCompletedTracking || redactionEditing) else {
            item.videoComposition=nil
            if !isPlaying {player?.seek(to:CMTime(seconds:currentTime,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)}
            return
        }
        let plan:RedactionPlan
        if let existing=project.redactionPlan,existing.covers(project),hasCompletedTracking {plan=existing}
        else {
            var tracks:[RedactionTrack]=[]
            if project.settings.redaction.allOthers,let primary=redactionPrimaryBody {
                tracks=AutomaticRedaction.candidates(observations,primary:primary).map { observation in
                    let rect=AutomaticRedaction.region(observation,options:project.settings.redaction,source:project.metadata.size)
                    return .init(subjectID:UUID(),frames:[.init(time:0,rect:rect),.init(time:project.metadata.duration,rect:rect)])
                }
            }
            for subject in project.settings.redaction.subjects {
                guard let anchor=subject.anchors.min(by:{abs($0.time-currentTime)<abs($1.time-currentTime)}),abs(anchor.time-currentTime)<0.06,
                      let observation=observations.max(by:{$0.body.iou(anchor.body)<$1.body.iou(anchor.body)}),observation.body.iou(anchor.body)>0.4,canRedactPerson(observation.body),
                      let rect=RedactionMotion.region(of:observation,settings:project.settings.redaction,source:project.metadata.size) else {continue}
                tracks.append(.init(subjectID:subject.id,frames:[.init(time:0,rect:rect),.init(time:project.metadata.duration,rect:rect)]))
            }
            plan = .init(subjects:project.settings.redaction.subjects,region:project.settings.redaction.region,start:0,end:project.metadata.duration,tracks:tracks)
        }
        redactionPreviewTask=Task { [weak self,weak item] in
            do {
                try await Task.sleep(for:.milliseconds(50))
                guard let track=try await item?.asset.loadTracks(withMediaType:.video).first else {return}
                let transform=try await track.load(.preferredTransform),natural=try await track.load(.naturalSize)
                let bounds=CGRect(origin:.zero,size:natural).applying(transform).standardized
                let upright=transform.concatenating(.init(translationX:-bounds.minX,y:-bounds.minY))
                let previewScale=min(1,1280/max(bounds.width,bounds.height))
                let previewSize=CGSize(width:floor(bounds.width*previewScale/2)*2,height:floor(bounds.height*previewScale/2)*2)
                let composition=RedactionRenderer.composition(trackID:track.trackID,range:CMTimeRange(start:.zero,duration:CMTime(seconds:project.metadata.duration,preferredTimescale:600)),transform:upright,source:bounds.size,output:previewSize,start:0,crops:[],plan:plan,strength:project.settings.redaction.strength,rate:project.metadata.frameRate,style:project.settings.redaction.style,imageData:project.settings.redaction.imageData)
                guard let self,!Task.isCancelled,self.redactionPreviewID==id,self.project?.id==project.id else {return}
                item?.videoComposition=composition
                // AVPlayer can retain its paused source frame after a compositor change.
                // Seek the same timestamp to request a newly shaded frame immediately.
                if !self.isPlaying,let item {
                    item.seekingWaitsForVideoCompositionRendering=true
                    _ = await item.seek(to:CMTime(seconds:self.currentTime,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
                }
            } catch {
                guard let self,!Task.isCancelled,self.redactionPreviewID==id else {return}
                self.errorMessage="打码预览未能更新，请重试：\(error.localizedDescription)"
            }
        }
    }
}

extension AppModel {
    func setRedactionStyle(_ style:RedactionSettings.Style) {
        guard settingsEnabled,style != .image || project?.settings.redaction.region == .face else {return}
        if style == .image,project?.settings.redaction.imageData == nil {
            guard let data=RedactionSticker.duck.data else {errorMessage="内置贴片无法读取";return}
            project?.settings.redaction.imageData=data
        }
        project?.settings.redaction.style=style
        refreshRedactionPreview();persist()
    }
    func setRedactionSticker(_ sticker:RedactionSticker) {
        guard settingsEnabled,project?.settings.redaction.region == .face,let data=sticker.data else {return}
        project?.settings.redaction.imageData=data;project?.settings.redaction.style = .image
        refreshRedactionPreview();persist()
    }
    func importRedactionImage(_ data:Data) async {
        guard settingsEnabled,redactionEditing,project?.settings.redaction.region == .face,let projectID=project?.id else {return}
        let id=UUID();redactionImageID=id;importingRedactionImage=true
        do {
            let prepared=try await Task.detached(priority:.userInitiated) {try RedactionImage.prepare(data)}.value
            guard redactionImageID==id,project?.id==projectID,redactionEditing else {return}
            guard project?.settings.redaction.region == .face else {importingRedactionImage=false;return}
            project?.settings.redaction.imageData=prepared;project?.settings.redaction.style = .image
            importingRedactionImage=false;refreshRedactionPreview();persist()
        } catch {
            guard redactionImageID==id else {return}
            importingRedactionImage=false;errorMessage="图片读取失败，请选择其他图片。"
        }
    }
}

extension AppModel {
    private func receiveRegenerationProgress(_ progress:Double,id:UUID,projectID:UUID) {
        guard progress.isFinite,isCurrent(id,projectID:projectID),case .processing = phase else {return}
        let base=generationAnalysisWeight+generationRedactionWeight
        phase = .processing(progress:max(phase.progress,base+min(1,max(0,progress))*(0.99-base)))
    }
}


extension AppModel {
    #if DEBUG
    func prepareAnalysisReviewDemo() {
        startDemo()
        project?.metadata = .init(width:1920,height:1080,duration:1,frameRate:30)
        project?.settings.end=1
        let box=DemoStage.body(index:1,time:0)
        project?.target=box;project?.targetTime=0
        let frames=[AnalysisReviewFrame(time:1.0/6),AnalysisReviewFrame(time:0.5)]
        let batch=DetectionBatch(primary:[.init(id:1,body:box,confidence:1)],relaxed:[])
        analysisReview = .init(frames:frames,samples:(0...6).filter {$0 != 1 && $0 != 3}.map {.init(time:Double($0)/6,body:box)},
            people:[1667:batch,5000:batch],detected:[1667,5000])
        selectReviewFrame(at:1.0/6)
    }
    #endif
    /// Review navigation never resumes the tracking pipeline. A completed request is cached even when empty.
    func selectReviewFrame(at time:Double) {
        guard isReviewing,!restoringTracking,time.isFinite,let frame=reviewFrames.min(by:{abs($0.time-time)<abs($1.time-time)}),let project else {return}
        pausePreview(refresh:false);processingPreview=nil;manualSelection=false
        currentTime=frame.time;reviewSelection=frame.body;targetExplicitlySelected=frame.body != nil
        phase = .blocked(.init(time:frame.time,message:"请选择与开始时相同的主角",checkpoint:1))
        player?.seek(to:CMTime(seconds:frame.time,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
        let key=frame.id
        observations=analysisReview?.detected.contains(key) == true ? analysisReview?.people[key]?.primary ?? [] : []
        detecting=reviewTasks[key] != nil
        guard frame.body == nil,analysisReview?.detected.contains(key) != true,reviewTasks[key] == nil,
              let source=store.sourceURL(for:project) else {return}
        detecting=true;detectionNotice=nil
        let token=reviewID,pipeline=self.pipeline
        reviewTasks[key]=Task { [weak self] in
            do {
                let found=try await pipeline.detections(source:source,time:frame.time,region:nil)
                guard let self,!Task.isCancelled,self.reviewID==token,self.project?.id==project.id,self.isReviewing else {return}
                self.analysisReview?.people[key] = .init(primary:found,relaxed:[])
                self.analysisReview?.detected.insert(key)
                self.analyzedPeople[key] = .init(primary:found,relaxed:[])
                self.reviewTasks[key]=nil
                if abs(self.currentTime-frame.time)<0.001 {
                    self.observations=found;self.detecting=false
                    self.detectionNotice=found.isEmpty ? "未识别到人物，可直接手动框选" : nil
                }
                self.persist()
            } catch {
                guard let self,self.reviewID==token,self.project?.id==project.id,self.isReviewing else {return}
                // A failed request is also attempted once; the human can always supply the box.
                self.analysisReview?.detected.insert(key);self.reviewTasks[key]=nil
                self.analysisReview?.people[key] = .init(primary:[],relaxed:[])
                if abs(self.currentTime-frame.time)<0.001 {self.detecting=false;self.observations=[];self.detectionNotice="识别失败，请手动框选人物"}
                self.persist()
            }
        }
    }
    func moveReview(_ direction:Int) {
        let pending=reviewFrames.filter {$0.body == nil}.sorted {$0.time<$1.time}
        let next=direction>0 ? pending.first {$0.time>currentTime+0.001} : pending.last {$0.time<currentTime-0.001}
        if let next {selectReviewFrame(at:next.time)}
    }
    func confirmReviewFrame() {
        guard isReviewing,!restoringTracking,let box=reviewSelection,
              analysisReview?.confirm(time:currentTime,box:box) == true else {return}
        targetSamples=analysisReview?.samples ?? [];targetExplicitlySelected=true
        persist()
        if analysisReview?.pending.isEmpty == true {completeReview()}
    }
    private func completeReview() {
        guard let review=analysisReview,review.pending.isEmpty,let project else {return}
        do {try VideoExporter.validateTrajectory(review.samples,project:project)}
        catch {errorMessage="确认数据不完整，请重新分析";return}
        let id=operationID,token=reviewID,previous=persistenceTask
        restoringTracking=true
        processingTask=Task { [weak self,store=self.store,pipeline=self.pipeline] in
            await previous?.value
            guard let self,!Task.isCancelled,self.isCurrent(id,projectID:project.id),self.reviewID==token else {return}
            do {
                try await store.saveTrajectory(project:project,samples:review.samples,people:review.people)
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id),self.reviewID==token else {return}
                if let source=store.sourceURL(for:project) {await pipeline.restorePeople(review.people,source:source)}
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id),self.reviewID==token else {return}
                self.reviewID=UUID();self.reviewTasks.values.forEach {$0.cancel()};self.reviewTasks=[:]
                self.targetSamples=review.samples;self.analyzedPeople=review.people
                self.analysisReview=nil;self.reviewSelection=nil;self.hasCompletedTracking=true
                self.restoringTracking=false;self.detecting=false;self.detectionNotice=nil;self.manualSelection=false
                self.phase = .editing;self.route = .editor;self.generatingVideo=false;self.analysisOnly=false
                self.seek(to:project.settings.start);self.persist()
            } catch {
                guard self.isCurrent(id,projectID:project.id),self.reviewID==token else {return}
                self.restoringTracking=false;self.errorMessage="确认结果保存失败：\(error.localizedDescription)"
            }
        }
    }
}
