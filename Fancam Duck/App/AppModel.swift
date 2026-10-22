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
        let redactionRevision:Int?
        init(_ project:VideoProject) {
            projectID=project.id;sourceFileName=project.sourceFileName;metadata=project.metadata
            target=project.target;targetTime=project.targetTime;settings=project.settings
            redactionRevision=project.settings.redaction.enabled ? project.redactionPlan?.smoothingVersion : nil
        }
    }
    private var lastGeneratedRecipe:GenerationRecipe?
    var needsRegeneration:Bool {
        guard let project,let recipe=lastGeneratedRecipe,recipe.projectID==project.id else {return false}
        return recipe != GenerationRecipe(project)
    }
    var hasReusableOutput:Bool {
        guard let project,let outputURL,lastGeneratedRecipe==GenerationRecipe(project) else {return false}
        if project.settings.redaction.enabled,project.redactionPlan?.covers(project) != true {return false}
        return FileManager.default.fileExists(atPath:outputURL.path)
    }
    private var compositionAutomaticSettings:EditSettings?
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
    private var compositionSubjects:[SubjectFraming.Frame]=[]
    private var compositionDisplayTime:Double=0
    private var compositionAutomaticFrames:[CropPlan.Frame]=[]
    private var compositionTask:Task<Void,Never>?
    private var compositionPreviewReady=false
    private var compositionPreviewRedactions:RedactionPlan?
    private var compositionPlaybackRequested=false
    var previewPlaybackPending:Bool {compositionPlaybackRequested && !isPlaying}
    private var compositionID=UUID()
    var compositionDisplayedScale:Double {
        guard let automatic=compositionAutomatic,let crop=compositionCrop,crop.height>0 else {return project?.settings.compositionScale ?? 1}
        return automatic.height/crop.height
    }
    private var detectionTask: Task<Void, Never>?
    var isPlaying = false
    private var previewTask: Task<Void,Never>?
    @ObservationIgnored private let timelineSeeker = VideoSeekCoalescer()
    @ObservationIgnored private var scrubID = UUID()
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
        guard !isReviewing,!restoringTracking,!detecting,!isPlaying,!manualSelection,(!compositionBusy || hasCompletedTracking),!compositionAdjusting,let project,
              (hasCompletedTracking || hasReusableOutput || (project.targetTime>=project.settings.start && project.targetTime<=project.settings.end)) else { return false }
        return ProcessingGate.canContinue(phase: phase, target: project.target, explicitlySelected: targetExplicitlySelected)
    }
    var controlsEnabled: Bool { phase.canEditTarget }
    // Persisted status only selects the opening UI; validated trajectories still gate playback/export.
    var showsPreviewSettings:Bool {
        hasCompletedTracking || restoringTracking && ["已分析 · 可预览","已生成 · 待保存","已保存到相册"].contains(project?.progressState ?? "")
    }
    var settingsEnabled: Bool { phase == .editing && !restoringTracking }
    var editorActivityText: String? {
        if restoringTracking {return showsPreviewSettings ? nil : "正在打开项目"}
        if compositionBusy && !hasCompletedTracking {return "正在准备构图预览 · 可取消"}
        if detecting {return project?.target == nil ? "正在识别人物 · 请稍候" : "正在识别当前帧 · 可调整设置"}
        return nil
    }
    var statusText: String {
        switch phase {
        case .editing:
            if restoringTracking {return showsPreviewSettings ? "预览" : "正在打开项目"}
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
        manualSelection = false
        outputURL = nil
        savedToPhotos = false
    }
    func importMovie(_ movie: ImportedMovie) async {
        await importMovie(load:{movie})
    }
    func importMovie(load:() async throws -> ImportedMovie?) async {
        let id=UUID();importID=id
        importing = true
        var received:ImportedMovie?
        defer {
            if importID==id { importing=false }
            if let received {try? FileManager.default.removeItem(at:received.url)}
        }
        var copied:URL?
        var savedProject:VideoProject?
        do {
            guard let movie=try await load() else {
                if importID==id,!Task.isCancelled {errorMessage="未能读取所选视频，请重试。"}
                return
            }
            received=movie
            guard importID==id else {throw CancellationError()}
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
        targetExplicitlySelected = false
        thumbnails = []
        outputURL = nil
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
                if let output {self.outputURL=output.url;self.savedToPhotos=output.savedToPhotos;self.lastGeneratedRecipe=GenerationRecipe(project)}
                if let cached {
                    self.targetSamples=SubjectFraming.withCachedPoses(cached,people:people ?? [:]);self.hasCompletedTracking=true
                    if let current=self.project {
                        let conflicts=RedactionPolicy.conflicts(project:current,samples:cached)
                        if !conflicts.isEmpty {
                            self.project?.settings.redaction.subjects.removeAll {conflicts.contains($0.id)}
                            self.project?.redactionPlan=nil;self.outputURL=nil;self.savedToPhotos=false
                            self.persist()
                        }
                    }
                    if let anchor=project.settings.compositionAnchor {
                        self.currentTime=min(project.settings.end,max(project.settings.start,anchor.time))
                        self.player?.seek(to:CMTime(seconds:self.currentTime,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero,completionHandler:{_ in})
                    }
                    self.refreshRedactionPreview()
                    return
                }
                if output == nil && (project.targetTime<project.settings.start || project.targetTime>project.settings.end) {
                    self.project?.target=nil;self.project?.settings.compositionAnchor=nil;self.targetExplicitlySelected=false
                }
                if let review {
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
        guard !restoringTracking,controlsEnabled, rect.isValid, rect.width > 0.015, rect.height > 0.03 else { return }
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
        hasCompletedTracking=false;targetSamples=[];analyzedPeople=[:];outputURL=nil;savedToPhotos=false
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
                    self.outputURL=output;self.savedToPhotos=false
                    self.lastGeneratedRecipe=GenerationRecipe(renderProject)
                    self.exportPoster=nil;self.previewPlayer=AVPlayer(url:output)
                    self.generatingVideo=false;self.phase = .completed(output);self.route = self.generateAfterAnalysis ? .editor : .export;self.persist();return
                }
                let item=try await exporter.preview(source:url,project:renderProject,samples:result.samples)
                let poster=await self.poster(for:item)
                guard !Task.isCancelled,self.isCurrent(id,projectID:project.id) else { return }
                self.exportPoster=poster;self.previewPlayer=AVPlayer(playerItem:item)
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
                        let index=max(0,min(3,Int(((project.target!.center.x*360-57)/82).rounded())))
                        self.targetSamples=(0...Int(ceil((project.settings.end-project.settings.start)*AnalysisSampling.frequency))).map {i in
                            let time=min(project.settings.end,project.settings.start+Double(i)/AnalysisSampling.frequency)
                            return .init(time:time,body:DemoStage.body(index:index,time:time))
                        }
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
        targetExplicitlySelected=false;manualSelection=false
        outputURL=nil;lastGeneratedRecipe=nil;savedToPhotos=false
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
        guard !restoringTracking,phase == .editing else {return}
        if compositionEditing {toggleCompositionPlayback();return}
        if let project,hasCompletedTracking,project.settings.redaction.enabled,project.redactionPlan?.covers(project) != true {
            detectionNotice="确认处理后可播放完整打码效果";return
        }
        guard controlsEnabled, !manualSelection else { return }
        if isPlaying { pausePreview(); return }
        guard let project else { return }
        if currentTime >= project.settings.end-0.05 { seek(to:project.settings.start) }
        detectionID=UUID();detectionTask?.cancel();detecting=false;observations=[]
        isPlaying=true; player?.play()
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
        compositionPlaybackRequested=false
        if compositionEditing {
            let wasPlaying=isPlaying
            isPlaying=false;previewTask?.cancel();previewPlayer?.pause();player?.pause()
            if wasPlaying,let project,hasCompletedTracking,let time=previewPlayer?.currentTime().seconds,time.isFinite {
                currentTime=min(project.settings.end,max(project.settings.start,project.settings.start+time))
                synchronizeCompositionPosition()
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
    var canScrubGeneratedPreview:Bool {
        if case .completed = phase {return true}
        return phase == .readyToExport
    }
    func seek(to time: Double) {
        guard let project else { return }
        if canScrubGeneratedPreview {
            cancelTimelineScrubbing()
            scrubGeneratedPreview(to:time,exact:true);return
        }
        if isReviewing {selectReviewFrame(at:time);return}
        if compositionEditing {
            guard hasCompletedTracking,time.isFinite else { return }
            cancelTimelineScrubbing()
            currentTime=min(project.settings.end,max(project.settings.start,time))
            scrubComposition(exact:true)
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
        guard !restoringTracking else {return}
        if canScrubGeneratedPreview {scrubGeneratedPreview(to:time,exact:false);return}
        guard phase == .editing else {return}
        if compositionEditing && !hasCompletedTracking && !sourceOnly {return}
        if compositionEditing,hasCompletedTracking,let project,time.isFinite {
            if isPlaying {pausePreview(refresh:false)} else {previewTask?.cancel()}
            let limits=bounds ?? project.settings.start...project.settings.end
            currentTime=min(limits.upperBound,max(limits.lowerBound,time))
            scrubComposition(exact:false)
            return
        }
        guard controlsEnabled,let project,time.isFinite else {return}
        pausePreview(refresh:false)
        detectionID=UUID();detectionTask?.cancel();detecting=false;observations=[];detectionNotice=nil
        let lower = max(0, bounds?.lowerBound ?? project.settings.start)
        let upper = min(project.metadata.duration, bounds?.upperBound ?? project.settings.end)
        currentTime=min(upper,max(lower,time))
        player?.seek(to:CMTime(seconds:currentTime,preferredTimescale:60000),toleranceBefore:CMTime(seconds:0.1,preferredTimescale:600),toleranceAfter:CMTime(seconds:0.1,preferredTimescale:600))
    }
    func finishScrubbing(within bounds:ClosedRange<Double>? = nil) {
        if canScrubGeneratedPreview {scrubGeneratedPreview(to:currentTime,exact:true);return}
        if compositionEditing {
            guard hasCompletedTracking else {return}
            scrubComposition(exact:true)
            if let project {
                previewPlayer?.seek(to:CMTime(seconds:max(0,currentTime-project.settings.start),preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
            }
            return
        }
        if let bounds, let project, controlsEnabled {
            currentTime = min(project.metadata.duration, min(bounds.upperBound, max(bounds.lowerBound, currentTime)))
            player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
            if !isDemo { detectPeople() }
        } else { seek(to:currentTime) }
    }
    private func scrubGeneratedPreview(to time:Double,exact:Bool) {
        guard canScrubGeneratedPreview,time.isFinite,let project else {return}
        currentTime=min(project.settings.end,max(project.settings.start,time))
        guard let player=previewPlayer,let item=player.currentItem else {return}
        if player.rate != 0 {player.pause()}
        let position=currentTime-project.settings.start,id=scrubID,projectID=project.id
        let tolerance=CMTime(seconds:exact ? 0 : 1/30,preferredTimescale:60000)
        timelineSeeker.submit(.init(perform:{[weak self,weak player,weak item] done in
            guard let self,let player,let item,self.scrubID==id,self.project?.id==projectID,
                  self.canScrubGeneratedPreview,player.currentItem===item else {done();return}
            player.seek(to:CMTime(seconds:position,preferredTimescale:60000),toleranceBefore:tolerance,toleranceAfter:tolerance) {_ in
                Task {@MainActor in done()}
            }
        },cancel:{[weak item] in item?.cancelPendingSeeks()}))
    }
    // Completed trajectories retain the original analyzed bounds even after narrowing a trim.
    var trimBounds:ClosedRange<Double>? {
        guard let project else {return nil}
        guard hasCompletedTracking else {return 0...max(0,project.metadata.duration)}
        let times=targetSamples.map(\.time).filter(\.isFinite)
        let lower=max(0,min(project.settings.start,times.min() ?? project.settings.start))
        let upper=max(lower,min(project.metadata.duration,max(project.settings.end,times.max() ?? project.settings.end)))
        return lower...upper
    }
    func updateRange(start: Double? = nil, end: Double? = nil, previewTime: Double? = nil) {
        guard settingsEnabled,!compositionAdjusting,
              start?.isFinite != false,end?.isFinite != false,previewTime?.isFinite != false,
              let project else { return }
        pausePreview(refresh:false)
        cancelTimelineScrubbing()
        let wasAnalyzed=hasCompletedTracking
        let bounds=trimBounds ?? 0...project.metadata.duration
        let minimum = min(0.5, bounds.upperBound-bounds.lowerBound)
        var settings = project.settings
        let upper=min(bounds.upperBound,max(bounds.lowerBound+minimum,end ?? settings.end))
        if let start { settings.start = min(max(bounds.lowerBound,start),upper-minimum) }
        if let end { settings.end = min(bounds.upperBound,max(settings.start+minimum,end)) }
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
        // Opening/closing a project must not downgrade its persisted analysis status.
        if !restoringTracking {
            switch phase {
            case .completed:project.progressState=savedToPhotos ? "已保存到相册" : "已生成 · 待保存"
            case .blocked:project.progressState="待纠正"
            case .processing,.paused:project.progressState="处理中断"
            default:project.progressState=hasCompletedTracking ? "已分析 · 可预览" : (project.target == nil ? "待选人" : "待处理")
            }
        }
        project.updatedAt=Date();self.project=project
        let review=analysisReview
        let preserveReview=restoringTracking
        let previous=persistenceTask
        persistenceTask=Task {
            await previous?.value
            do {
                try await store.save(project)
                if let review {try await store.saveReview(review,project:project)}
                else if !preserveReview {try await store.removeReview(project.id)}
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
        let preserve=hasCompletedTracking,time=currentTime
        cancelTasks(preserveAnalysis:preserve);route = .editor;phase = .editing
        seek(to:preserve ? time : (project?.targetTime ?? time))
    }
    func openExportPreview() async {
        guard route == .editor,settingsEnabled,hasCompletedTracking,!compositionAdjusting,let project else {return}
        pausePreview(refresh:false)
        if !compositionEditing {beginComposition()}
        let id=compositionID,settings=project.settings
        await compositionTask?.value
        guard !Task.isCancelled,route == .editor,settingsEnabled,compositionID==id,
              self.project?.id==project.id,self.project?.settings==settings,
              isDemo || compositionPreviewReady else {return}
        if settings.redaction.enabled,!isDemo {
            guard let plan=compositionPreviewRedactions,plan.covers(project) else {return}
            self.project?.redactionPlan=plan
        }
        if redactionEditing {finishRedaction(commit:true,keepComposition:true)}
        finishComposition(commit:true,refreshDetections:false)
        if hasReusableOutput,let outputURL {
            previewPlayer=AVPlayer(url:outputURL);phase = .completed(outputURL)
        } else {phase = .readyToExport}
        route = .export
    }
    func skipPreview(by seconds:Double) {
        guard settingsEnabled,hasCompletedTracking,compositionEditing,seconds.isFinite else {return}
        let resume=isPlaying || previewPlaybackPending,target=currentTime+seconds
        pausePreview(refresh:false)
        scrub(to:target);finishScrubbing()
        if resume {togglePreview()}
    }
    func export() {
        guard phase == .readyToExport, phase.issue == nil else { return }
        cancelTimelineScrubbing()
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
                self.outputURL=output;self.lastGeneratedRecipe=GenerationRecipe(project);self.exportPoster=nil;self.exportProgress=1
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
    func suspend() { cancelTimelineScrubbing();pause();pausePreview(refresh:false);previewPlayer?.pause();persist() }
    private func cancelTasks(preserveAnalysis:Bool=false) {
        cancelTimelineScrubbing()
        reviewID=UUID();reviewTasks.values.forEach {$0.cancel()};reviewTasks=[:]
        analysisReview=nil;reviewSelection=nil
        if redactionEditing { finishRedaction(commit:true) }
        generatingVideo=false;analysisOnly=false;generateAfterAnalysis=false
        redactionIssue=nil;redactionPreviewID=UUID();redactionPreviewTask?.cancel()
        if compositionEditing { finishComposition(commit:true,refreshDetections:false) }
        restorationID=UUID();restorationTask?.cancel();restoringTracking=false;savingToPhotos=false;detectionNotice=nil;cancellingExport=false;exportProgress=0
        compositionTask?.cancel();compositionID=UUID();compositionBusy=false;compositionPreviewReady=false;compositionFrames=[];compositionAutomaticFrames=[];compositionSubjects=[]
        pausePreview(refresh:false);operationID=UUID();detectionID=UUID();importID=UUID();importing=false
        detectionTask?.cancel();detecting=false;observations=[]
        processingPreview=nil;trackedSample=nil
        if !preserveAnalysis {
            targetSamples=[];hasCompletedTracking=false;selectionObservation=nil;analyzedPeople=[:]
            compositionCrop=nil;compositionAutomatic=nil
        }
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
        pausePreview(refresh:false);manualSelection=false
        compositionSnapshot=project?.settings;compositionUndo=[];compositionEditing=true;compositionNotice=nil
        if !hasCompletedTracking {compositionCrop=nil}
        else if let crop=CropPlan.rect(at:currentTime,in:compositionFrames) {compositionCrop=crop}
        compositionAutomatic=nil;compositionFrames=[];compositionAutomaticFrames=[];compositionAutomaticSettings=nil
        if !hasCompletedTracking { currentTime=project?.settings.compositionAnchor?.time ?? project?.targetTime ?? currentTime }
        player?.seek(to:CMTime(seconds:currentTime,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
        compositionDisplayTime=currentTime
        refreshComposition()
    }
    func finishComposition(commit:Bool,refreshDetections:Bool=true) {
        guard compositionEditing else { return }
        cancelTimelineScrubbing()
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
        pauseForPreviewChange()
        cancelTimelineScrubbing(settle:true)
        compositionPreviewReady=false
        compositionPreviewRedactions=nil
        compositionTask?.cancel();let id=UUID();compositionID=id
        let samples=compositionSamples,settings=project.settings,source=project.metadata.size
        let people=analyzedPeople.sorted {$0.key<$1.key}.map {(Double($0.key)/10000,$0.value)}
        compositionSubjects=SubjectFraming.make(samples,source:source)
        var automatic=settings;automatic.subjectComposition=settings.subjectComposition == nil ? nil : .init();automatic.compositionScale=1;automatic.compositionX=0;automatic.compositionY=0;automatic.compositionAnchor=nil
        let cachedAutomatic=compositionAutomaticSettings==automatic ? compositionAutomaticFrames : []
        compositionBusy=true
        compositionTask=Task { [weak self] in
            let calculation=Task.detached(priority:.userInitiated) {
                (CropPlan.renderFrames(CropPlan.make(samples:samples,source:source,settings:settings),frameRate:project.metadata.frameRate,preserving:settings.compositionAnchor?.time),
                 cachedAutomatic.isEmpty ? CropPlan.renderFrames(CropPlan.make(samples:samples,source:source,settings:automatic),frameRate:project.metadata.frameRate) : cachedAutomatic)
            }
            let computed=await withTaskCancellationHandler {
                await calculation.value
            } onCancel: {
                calculation.cancel()
            }
            guard let self,!Task.isCancelled,self.compositionEditing,self.compositionID==id,self.project?.id==project.id else { return }
            self.compositionFrames=computed.0;self.compositionAutomaticFrames=computed.1;self.compositionAutomaticSettings=automatic
            self.synchronizeCompositionPosition(at:self.compositionDisplayTime)

            do {
                var rendering=project
                if self.hasCompletedTracking,settings.redaction.enabled,project.redactionPlan?.covers(project) != true,
                   settings.redaction.allOthers,!people.isEmpty {
                    let masks=Task.detached(priority:.userInitiated) {
                        try AutomaticRedaction.build(frames:people,project:project,samples:samples)
                    }
                    let plan=try await withTaskCancellationHandler {try await masks.value} onCancel:{masks.cancel()}
                    guard !Task.isCancelled,self.compositionEditing,self.compositionID==id,self.project?.id==project.id else {return}
                    // Preview-only cache reuse must not mark the export recipe as generated.
                    if plan.covers(project) {rendering.redactionPlan=plan}
                }
                if self.hasCompletedTracking,settings.redaction.enabled,rendering.redactionPlan?.covers(rendering) != true {
                    self.previewPlayer?.pause();self.previewPlayer=nil
                    self.compositionNotice="完整打码轨迹尚未准备好"
                } else if self.hasCompletedTracking,let url=self.store.sourceURL(for:project) {
                    let item=try await self.exporter.preview(source:url,project:rendering,samples:samples)
                    guard !Task.isCancelled,self.compositionEditing,self.compositionID==id,self.project?.id==project.id else { return }
                    if let player=self.previewPlayer {player.replaceCurrentItem(with:item)}
                    else {self.previewPlayer=AVPlayer(playerItem:item)}
                    self.previewPlayer?.seek(to:CMTime(seconds:self.currentTime-settings.start,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero,completionHandler:{_ in})
                    self.compositionPreviewReady=true
                    self.compositionPreviewRedactions=rendering.redactionPlan
                }
                self.compositionBusy=false
                if self.compositionPlaybackRequested {self.startCompositionPlayback()}
            } catch {
                guard self.compositionID==id,!Task.isCancelled else {return}
                self.compositionPlaybackRequested=false
                self.compositionBusy=false;self.errorMessage=error.localizedDescription
            }
        }
    }
    func beginCompositionGesture() {
        guard compositionEditing,settingsEnabled,compositionCrop != nil,compositionSubject != nil else {return}
        pauseForPreviewChange()
        // A new edit supersedes the pending calculation instead of locking the canvas.
        compositionTask?.cancel();compositionID=UUID();compositionBusy=false
        compositionGestureSettings=project?.settings;compositionAdjusting=true;compositionNotice=nil
    }
    var compositionSubject:SubjectFraming.Frame? {SubjectFraming.frame(at:compositionDisplayTime,in:compositionSubjects)}
    var compositionPrimaryBody:NormalizedRect? {hasCompletedTracking ? compositionSubject?.body : nil}
    var compositionReadout:(height:Double,x:Double,y:Double)? {
        guard let subject=compositionSubject,let crop=compositionCrop,let project,crop.height>0 else {return nil}
        return (subject.height*project.metadata.height/crop.height,
                (subject.center.x*project.metadata.width-crop.minX)/crop.width-0.5,
                (subject.center.y*project.metadata.height-crop.minY)/crop.height-0.5)
    }
    func compositionCentered(horizontal:Bool)->Bool {
        guard let actual=compositionReadout,let target=project?.settings.subjectComposition else {return false}
        return abs(horizontal ? target.x : target.y)<0.00001 && abs(horizontal ? actual.x : actual.y)<=0.005
    }
    var compositionStatusText:String {
        guard let value=compositionReadout else {return "人物 — · 水平 — · 垂直 —"}
        func percent(_ value:Double)->String {abs(value*100).rounded().formatted(.number.precision(.fractionLength(0)))+"%"}
        let x=(value.x*100).rounded()==0 || compositionCentered(horizontal:true) ? "水平 0%" : (value.x<0 ? "左 " : "右 ")+percent(value.x)
        let y=(value.y*100).rounded()==0 || compositionCentered(horizontal:false) ? "垂直 0%" : (value.y<0 ? "上 " : "下 ")+percent(value.y)
        return "人物 \(percent(value.height)) · \(x) · \(y)"
    }
    var compositionAlignmentNotice:String? {
        guard let value=compositionReadout,let target=project?.settings.subjectComposition else {return nil}
        if abs(value.x-target.x)>0.01 || abs(value.y-target.y)>0.01 || abs(value.height-target.height)>0.015 {
            return "原片边缘限制 · 目标人物 \(Int((target.height*100).rounded()))% · 水平 \(Int((target.x*100).rounded()))% · 垂直 \(Int((target.y*100).rounded()))%"
        }
        return nil
    }
    private func currentSubjectTarget()->SubjectComposition? {
        guard let actual=compositionReadout else {return nil}
        if project?.settings.compositionAnchor == nil,let target=project?.settings.subjectComposition {return target}
        return .init(height:actual.height,x:actual.x,y:actual.y)
    }
    private func displaySubjectCrop() {
        guard let subject=compositionSubject,let project,let target=project.settings.subjectComposition else {return}
        compositionCrop=SubjectFraming.crop(subject,source:project.metadata.size,aspect:project.settings.aspectRatio,target:target)
    }
    func applyCompositionCrop(_ proposed:CGRect) {
        guard compositionEditing,let project,let subject=compositionSubject,
              proposed.minX.isFinite,proposed.minY.isFinite,proposed.width.isFinite,proposed.height.isFinite,proposed.height>0 else {return}
        let reference=TargetSample(time:compositionDisplayTime,body:subject.body)
        let crop=CompositionGeometry.constrain(proposed,source:project.metadata.size,samples:compositionSamples,reference:reference,protect:false,aspect:project.settings.aspectRatio)
        compositionCrop=crop
        let target=SubjectComposition(height:subject.height*project.metadata.height/crop.height,
            x:(subject.center.x*project.metadata.width-crop.minX)/crop.width-0.5,
            y:(subject.center.y*project.metadata.height-crop.minY)/crop.height-0.5)
        self.project?.settings.subjectComposition=target
        self.project?.settings.compositionAnchor=nil
        self.project?.settings.compositionScale=(compositionAutomatic?.height ?? crop.height)/crop.height
        self.project?.settings.compositionX=target.x
        self.project?.settings.compositionY=target.y
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
        guard factor.isFinite,factor>0,let crop=compositionCrop else {return}
        beginCompositionGesture()
        guard compositionAdjusting else {return}
        if var target=currentSubjectTarget() {
            target.height *= factor
            project?.settings.subjectComposition=target;project?.settings.compositionAnchor=nil
            displaySubjectCrop()
            if let adjusted=compositionCrop {
                project?.settings.compositionScale=(compositionAutomatic?.height ?? adjusted.height)/adjusted.height
                project?.settings.compositionX=target.x;project?.settings.compositionY=target.y
            }
        } else {
            applyCompositionCrop(CompositionGeometry.transformed(crop,scale:factor,translation:.zero,anchor:.init(x:0.5,y:0.5),viewport:.init(width:1,height:1)))
        }
        endCompositionGesture()
    }
    func compositionMove(x:Double,y:Double) {
        guard x.isFinite,y.isFinite,x != 0 || y != 0,let crop=compositionCrop else {return}
        beginCompositionGesture();guard compositionAdjusting else {return};applyCompositionCrop(crop.offsetBy(dx:-x*crop.width,dy:-y*crop.height));endCompositionGesture()
    }
    func setCompositionAspect(_ aspect: OutputAspectRatio) {
        // A newer selection supersedes the pending preview through compositionID/cancellation.
        guard compositionEditing,!compositionAdjusting,
              let project,project.settings.aspectRatio != aspect else {return}
        pauseForPreviewChange()
        compositionUndo.append(project.settings)
        let target=currentSubjectTarget()
        self.project?.settings.subjectComposition=target;self.project?.settings.compositionAnchor=nil
        self.project?.settings.aspectRatio=aspect
        let sizes=OutputResolution.available(for:project.metadata,aspect:aspect)
        // Preserve the selected quality budget where possible, without upscaling the source.
        self.project?.settings.resolution=sizes.last(where: {max($0.width,$0.height)<=max(project.settings.resolution.width,project.settings.resolution.height)}) ?? sizes.first ?? project.settings.resolution
        if let automatic=compositionAutomatic {
            compositionAutomatic=CompositionGeometry.reframed(automatic,source:project.metadata.size,aspect:aspect)
        }
        displaySubjectCrop()
        refreshComposition();persist()
    }
    func centerComposition(horizontal:Bool) {
        guard compositionEditing,!compositionAdjusting,var target=currentSubjectTarget() else {return}
        beginCompositionGesture();guard compositionAdjusting else {return}
        if horizontal {target.x=0} else {target.y=0}
        project?.settings.subjectComposition=target;project?.settings.compositionAnchor=nil
        displaySubjectCrop();endCompositionGesture()
    }
    func resetComposition(centerOnly:Bool=false) {
        guard compositionEditing,!compositionAdjusting,let settings=project?.settings else {return}
        compositionUndo.append(settings)
        var target=currentSubjectTarget() ?? .init();target.x=0;target.y=0
        if !centerOnly {target.height=SubjectComposition().height}
        project?.settings.subjectComposition=target;project?.settings.compositionAnchor=nil
        displaySubjectCrop();refreshComposition();persist()
    }
    func undoComposition() {
        guard compositionEditing,!compositionAdjusting,let before=compositionUndo.popLast() else {return}
        project?.settings=before;refreshComposition()
    }
    func setFollowSpeed(_ speed: EditSettings.FollowSpeed) {
        guard settingsEnabled, !compositionAdjusting,
              project?.settings.followSpeed != speed else { return }
        pauseForPreviewChange()
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
    private func synchronizeCompositionPosition(at time:Double? = nil) {
        compositionDisplayTime=time ?? currentTime
        compositionCrop=CropPlan.rect(at:time ?? currentTime,in:compositionFrames)
        compositionAutomatic=CropPlan.rect(at:time ?? currentTime,in:compositionAutomaticFrames)
    }
    private func cancelTimelineScrubbing(settle:Bool=false) {
        let wasSeeking=timelineSeeker.isSeeking
        scrubID=UUID()
        timelineSeeker.cancel()
        if settle && wasSeeking,let player,let item=player.currentItem,let project {
            let token=scrubID
            player.seek(to:CMTime(seconds:currentTime,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero) { [weak self,weak player,weak item] finished in
                Task { @MainActor in
                    guard finished,let self,let player,let item,self.scrubID==token,
                          self.project?.id==project.id,self.compositionEditing,player.currentItem===item else {return}
                    let time=player.currentTime().seconds
                    if time.isFinite {self.synchronizeCompositionPosition(at:time)}
                }
            }
        }
    }
    private func scrubComposition(exact:Bool) {
        guard let project else {return}
        guard !isDemo,let player,let item=player.currentItem else {
            synchronizeCompositionPosition();return
        }
        let time=currentTime,id=scrubID,projectID=project.id
        // While dragging, allow a nearby decoded frame; settle exactly only on release.
        let tolerance=CMTime(seconds:exact ? 0 : 1/30,preferredTimescale:60000)
        timelineSeeker.submit(.init(perform:{ [weak self,weak player,weak item] done in
            guard let self,let player,let item,self.scrubID==id,
                  self.project?.id==projectID,player.currentItem===item else {done();return}
            player.seek(to:CMTime(seconds:time,preferredTimescale:60000),toleranceBefore:tolerance,toleranceAfter:tolerance) { [weak self,weak player,weak item] finished in
                Task { @MainActor in
                    if finished,let self,let player,let item,self.scrubID==id,
                       self.project?.id==projectID,self.compositionEditing,player.currentItem===item {
                        let displayed=player.currentTime().seconds
                        if displayed.isFinite {self.synchronizeCompositionPosition(at:displayed)}
                    }
                    done()
                }
            }
        },cancel:{ [weak item] in item?.cancelPendingSeeks() }))
    }
    private func pauseForPreviewChange() {
        let requested=compositionEditing && hasCompletedTracking && (isPlaying || compositionPlaybackRequested)
        pausePreview(refresh:false)
        compositionPlaybackRequested=requested
    }
    private func toggleCompositionPlayback() {
        guard hasCompletedTracking,!compositionAdjusting else {return}
        if isPlaying || compositionPlaybackRequested {pausePreview(refresh:false);return}
        compositionPlaybackRequested=true
        startCompositionPlayback()
    }
    private func startCompositionPlayback() {
        guard compositionPlaybackRequested,compositionEditing,settingsEnabled,!compositionBusy,!compositionAdjusting else {return}
        guard isDemo || (compositionPreviewReady && previewPlayer?.currentItem != nil && previewPlayer?.currentItem?.status != .failed) else {
            compositionPlaybackRequested=false
            errorMessage=compositionNotice ?? "播放预览尚未准备好，请稍后重试";return
        }
        if let project,currentTime>=project.settings.end-0.05 {seek(to:project.settings.start)}
        cancelTimelineScrubbing()
        synchronizeCompositionPosition()
        if let project {previewPlayer?.seek(to:CMTime(seconds:max(0,currentTime-project.settings.start),preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)}
        isPlaying=true;previewPlayer?.play()
        previewTask=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.milliseconds(80))} catch {return}
                guard let self,self.compositionEditing,self.isPlaying,let project=self.project else {return}
                if self.isDemo {self.currentTime=min(project.settings.end,self.currentTime+0.08)}
                else if let player=self.previewPlayer,player.currentItem != nil,
                        player.currentItem?.status != .failed,player.currentTime().seconds.isFinite {
                    self.currentTime=min(project.settings.end,max(project.settings.start,project.settings.start+player.currentTime().seconds))
                } else {
                    self.pausePreview(refresh:false);self.compositionNotice="预览暂不可用，请稍后重试";return
                }
                self.synchronizeCompositionPosition()
                if self.currentTime>=project.settings.end-0.02 {self.pausePreview(refresh:false);return}
            }
        }
    }
}

extension AppModel {
    func beginRedaction() {
        guard settingsEnabled,let project,project.target != nil,!redactionEditing else {return}
        let retainedComposition=compositionEditing
        if !retainedComposition {pausePreview(refresh:false)}
        if !hasCompletedTracking,abs(currentTime-project.targetTime)>0.05 {seek(to:project.targetTime)}
        if hasCompletedTracking {beginComposition()}
        redactionEditing=true;redactionSnapshot=project.settings.redaction;redactionPlanSnapshot=project.redactionPlan
        if !retainedComposition {refreshRedactionPreview()}
    }
    func finishRedaction(commit:Bool,keepComposition:Bool=false) {
        if !commit,let snapshot=redactionSnapshot {project?.settings.redaction=snapshot;project?.redactionPlan=redactionPlanSnapshot}
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
        project?.settings.redaction.region=region
        project?.settings.redaction.strength=RedactionSettings.defaultStrength(for:region)
        project?.redactionPlan=nil
        if region == .person,project?.settings.redaction.style == .image {project?.settings.redaction.style = .frosted}
        refreshRedactionPreview();persist()
    }
    func setRedactionMode(_ region:RedactionSettings.Region?) {
        guard settingsEnabled,var settings=project?.settings.redaction else {return}
        if let region {
            if settings.region != region {
                settings.region=region
                settings.strength=RedactionSettings.defaultStrength(for:region)
                if region == .person,settings.style == .image {settings.style = .frosted}
            }
            settings.allOthers=true
        } else {settings.allOthers=false}
        settings.subjects=[]
        guard settings != project?.settings.redaction else {return}
        project?.settings.redaction=settings;project?.redactionPlan=nil
        refreshRedactionPreview();persist()
    }
    func setRedactionStrength(_ value:Double) {
        guard settingsEnabled,value.isFinite else {return}
        project?.settings.redaction.strength=min(1,max(0,value))
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
        let cachedFrames=analyzedPeople.sorted {$0.key<$1.key}.map {(Double($0.key)/10000,$0.value)}
        let samples=targetSamples
        let plan:RedactionPlan?
        if let existing=project.redactionPlan,existing.covers(project),hasCompletedTracking {plan=existing}
        else if hasCompletedTracking,project.settings.redaction.allOthers,!cachedFrames.isEmpty {
            // A fixed opening-frame mask cannot preview another timeline position.
            plan=nil
        } else {
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
                let previewPlan:RedactionPlan
                if let plan {previewPlan=plan}
                else {
                    let calculation=Task.detached(priority:.userInitiated) {
                        try AutomaticRedaction.build(frames:cachedFrames,project:project,samples:samples)
                    }
                    previewPlan=try await withTaskCancellationHandler {try await calculation.value} onCancel:{calculation.cancel()}
                }
                guard let track=try await item?.asset.loadTracks(withMediaType:.video).first else {return}
                let transform=try await track.load(.preferredTransform),natural=try await track.load(.naturalSize)
                let bounds=CGRect(origin:.zero,size:natural).applying(transform).standardized
                let upright=transform.concatenating(.init(translationX:-bounds.minX,y:-bounds.minY))
                let previewScale=min(1,1280/max(bounds.width,bounds.height))
                let previewSize=CGSize(width:floor(bounds.width*previewScale/2)*2,height:floor(bounds.height*previewScale/2)*2)
                let composition=RedactionRenderer.composition(trackID:track.trackID,range:CMTimeRange(start:.zero,duration:CMTime(seconds:project.metadata.duration,preferredTimescale:600)),transform:upright,source:bounds.size,output:previewSize,start:0,crops:[],plan:previewPlan,strength:project.settings.redaction.strength,rate:project.metadata.frameRate,style:project.settings.redaction.style,imageData:project.settings.redaction.imageData)
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
    func prepareCompositionDemo() {
        startDemo()
        let body=DemoStage.body(index:1,time:0)
        project?.target=body;targetExplicitlySelected=true
        targetSamples=(0...350).map {i in
            let time=min(58.2,Double(i)/6)
            return .init(time:time,body:DemoStage.body(index:1,time:time))
        }
        hasCompletedTracking=true
        beginComposition()
    }
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
    var canRetryReviewDetection:Bool {
        guard isReviewing,!restoringTracking,!manualSelection,let frame=currentReviewFrame,
              frame.body == nil,reviewTasks[frame.id] == nil,let project else {return false}
        return store.sourceURL(for:project) != nil
    }
    /// Only an explicit retry invalidates this point's detection cache; confirmed boxes stay intact.
    func retryCurrentReviewDetection() {
        guard canRetryReviewDetection,let frame=currentReviewFrame else {return}
        analysisReview?.detected.remove(frame.id)
        analysisReview?.people.removeValue(forKey:frame.id)
        analysisReview?.failureMessages?.removeValue(forKey:frame.id)
        analyzedPeople.removeValue(forKey:frame.id)
        detectionNotice=nil
        selectReviewFrame(at:frame.time)
    }
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
        detectionNotice=frame.body == nil ? (analysisReview?.failureMessages?[key] ??
            (observations.isEmpty && analysisReview?.detected.contains(key) == true ? "未找到候选人物，可重新识别或手动框选" : nil)) : nil
        guard frame.body == nil,analysisReview?.detected.contains(key) != true,reviewTasks[key] == nil,
              let source=store.sourceURL(for:project) else {return}
        detecting=true;detectionNotice=nil
        let token=reviewID,pipeline=self.pipeline
        reviewTasks[key]=Task { [weak self] in
            do {
                let found=try await pipeline.detections(source:source,time:frame.time,region:nil)
                guard let self,!Task.isCancelled,self.reviewID==token,self.project?.id==project.id,self.isReviewing else {return}
                self.analysisReview?.people[key] = .init(primary:found,relaxed:[])
                self.analysisReview?.failureMessages?.removeValue(forKey:key)
                self.analysisReview?.detected.insert(key)
                self.analyzedPeople[key] = .init(primary:found,relaxed:[])
                self.reviewTasks[key]=nil
                if abs(self.currentTime-frame.time)<0.001 {
                    self.observations=found;self.detecting=false
                    self.detectionNotice=found.isEmpty ? "未找到候选人物，可重新识别或手动框选" : nil
                }
                self.persist()
            } catch {
                guard let self,!Task.isCancelled,self.reviewID==token,self.project?.id==project.id,self.isReviewing else {return}
                // Failures are cached until the user explicitly retries this point.
                self.analysisReview?.detected.insert(key);self.reviewTasks[key]=nil
                self.analysisReview?.people[key] = .init(primary:[],relaxed:[])
                let message="识别失败：\(error.localizedDescription) 可重新识别或手动框选。"
                var failures=self.analysisReview?.failureMessages ?? [:];failures[key]=message
                self.analysisReview?.failureMessages=failures
                if abs(self.currentTime-frame.time)<0.001 {self.detecting=false;self.observations=[];self.detectionNotice=message}
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
                self.targetSamples=SubjectFraming.withCachedPoses(review.samples,people:review.people);self.analyzedPeople=review.people
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
