import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: PhotosPickerItem?
    @State private var importingFile=false
    @State private var showingSettings=false
    @State private var pendingDelete: VideoProject?
    var body: some View {
        let isImporting = model.importing
        NavigationStack {
            Group {
            #if targetEnvironment(macCatalyst)
            desktopLibrary
            #else
            Group {
            if horizontalSizeClass == .regular {expandedLibrary}
            else {
            List {
                VStack(alignment:.leading,spacing:24) {
                    HStack(spacing: 10) {
                        BrandLogo()
                        Text("直拍鸭").font(.title2.weight(.semibold))
                        Spacer()
                        settingsButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("这一次，你是主角").font(.largeTitle.bold())
                        Text("将群舞变成你的个人直拍").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    Button { model.startDemo() } label: {
                        HStack(spacing:12) {
                            Image(systemName:"play.rectangle").font(.system(size:22)).frame(width:42,height:42).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:12))
                            VStack(alignment:.leading,spacing:4) { Text("第一次使用？").font(.system(size:14,weight:.semibold)); Text("了解选人、跟随和纠正").font(.system(size:12)).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName:"arrow.up.right").font(.system(size:13))
                        }.foregroundStyle(.primary).padding(14).background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:20))
                    }.buttonStyle(.plain).accessibilityLabel("第一次使用？了解选人、跟随和纠正")
                        .accessibilityIdentifier("startDemo")
                }
                .listRowInsets(EdgeInsets(top:24,leading:0,bottom:24,trailing:0))
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
                HStack {
                    Text("最近项目").font(.title3.bold())
                    Spacer()
                    Text("自动保存").font(.caption).foregroundStyle(.secondary)
                }.listRowInsets(EdgeInsets(top:0,leading:0,bottom:8,trailing:0))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                if model.projects.isEmpty {
                    Text("还没有项目，导入一段舞蹈视频开始吧。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top:8,leading:0,bottom:16,trailing:0))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                ForEach(model.projects) { project in
                    RecentProjectRow(project:project,onOpen:{ model.open(project) })
                        .listRowInsets(EdgeInsets(top:6,leading:0,bottom:6,trailing:0))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                            Button("删除",systemImage:"trash") { pendingDelete=project }
                                .tint(.red).accessibilityIdentifier("deleteProject-\(project.id)")
                        }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .padding(.horizontal,24).frame(maxWidth:900).frame(maxWidth:.infinity)
            }
            }
            .background { StudioBackground() }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge:.bottom) {
                VStack(spacing:10) {
                    PhotosPicker(selection:$selection,matching:.videos,photoLibrary:.shared()) {
                        HStack(spacing:10) { Image(systemName:isImporting ? "hourglass" : "plus"); Text(isImporting ? "正在读取视频…" : "导入舞蹈视频") }
                            .font(.system(size:16,weight:.semibold)).frame(maxWidth:.infinity).frame(height:56).contentShape(Capsule())
                            .foregroundStyle(.white)
                    }.buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 56).contentShape(Capsule())
                        .modifier(StudioGlassSurface(shape: Capsule(), selected: true)).accessibilityLabel(isImporting ? "正在读取视频…" : "导入舞蹈视频")
                        .disabled(isImporting).opacity(isImporting ? 0.45 : 1)
                    #if targetEnvironment(macCatalyst)
                    Button {importingFile=true} label: {
                        Label("从文件导入",systemImage:"folder.badge.plus").frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())
                    }.keyboardShortcut("o",modifiers:.command).disabled(isImporting)
                        .accessibilityIdentifier("importVideoFile")
                    #endif
                    Text("原片留在本机 · 成片保留原音").font(.system(size:11)).foregroundStyle(.secondary)
                }.frame(maxWidth:520).frame(maxWidth:.infinity).padding(.horizontal,24).padding(.top,16).padding(.bottom,8)
            }
            #endif
            }
            .sheet(isPresented:$showingSettings) {SettingsView()}
            .fileImporter(isPresented:$importingFile,allowedContentTypes:[.movie]) {result in
                guard case .success(let url)=result else {return}
                Task {
                    await model.importMovie(load:{
                        let scoped=url.startAccessingSecurityScopedResource()
                        defer {if scoped {url.stopAccessingSecurityScopedResource()}}
                        let copy=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                        try FileManager.default.copyItem(at:url,to:copy)
                        return ImportedMovie(url:copy)
                    })
                }
            }
            .sheet(isPresented: $model.showGuide) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("一个镜头，跟上动作。").font(.title2.bold())
                    Label("导入相册视频，调整时间范围", systemImage: "photo.on.rectangle")
                    Label("点选人物并确认处理", systemImage: "person.crop.circle")
                    Label("异常时重新指定目标，完成后导出", systemImage: "square.and.arrow.up")
                    Text("指引视频将在后续版本补充。处理遇到人物身份不确定时，请重新选择目标并确认继续。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    StudioAction(title: "知道了", symbol: "checkmark") { model.showGuide = false }
                }.padding(28).presentationDetents([.medium])
            }
            .alert("删除这个项目？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("删除项目", role: .destructive) {
                    if let project = pendingDelete { Task { await model.delete(project) } }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { Text("将删除编辑记录和应用内导入副本，不会删除相册原视频或已保存的成片。") }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                Task {
                    await model.importMovie(load:{try await item.loadTransferable(type:ImportedMovie.self)})
                    if selection == item {selection=nil}
                }
            }
        }.preferredColorScheme(.dark)
    }
    @ViewBuilder private var settingsButton:some View {
        if #available(iOS 26.0, *) {
            Button {showingSettings=true} label: {
                Label("设置",systemImage:"gearshape").labelStyle(.iconOnly)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
                .buttonStyle(.glass).buttonBorderShape(.circle).frame(width:44,height:44)
                .accessibilityIdentifier("openSettings")
        } else {
            Button {showingSettings=true} label: {
                Label("设置",systemImage:"gearshape").labelStyle(.iconOnly)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
                .buttonStyle(.bordered).buttonBorderShape(.circle).frame(width:44,height:44)
                .accessibilityIdentifier("openSettings")
        }
    }
    private var expandedLibrary:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack {
                    VStack(alignment:.leading,spacing:8) {
                        HStack(spacing: 10) {
                            BrandLogo(size: 32)
                            Text("直拍鸭").font(.headline)
                        }
                        Text("这一次，你是主角").font(.largeTitle.bold())
                        Text("将群舞变成你的个人直拍").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    settingsButton
                    Button {model.showGuide=true} label: {Image(systemName:"questionmark.circle").font(.title2).frame(width:48,height:48).contentShape(Rectangle())}
                        .buttonStyle(.plain).accessibilityLabel("查看操作指引")
                }
                HStack {
                    Text("最近项目").font(.title3.bold())
                    Spacer()
                    Text("编辑自动保存").font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:18) {
                    ForEach(model.projects) {project in
                        VStack(alignment:.leading,spacing:12) {
                            Button {model.open(project)} label: {
                                ProjectThumbnail(project:project,width:nil,height:160)
                            }.buttonStyle(.plain).accessibilityLabel(project.title).accessibilityIdentifier("openProject-\(project.id)")
                            HStack {
                                VStack(alignment:.leading,spacing:5) {
                                    Text(project.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text("\(project.metadata.duration.videoTime) · \(project.historyStatus)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength:0)
                                Menu {Button("删除项目",systemImage:"trash",role:.destructive) {pendingDelete=project}} label: {
                                    Image(systemName:"ellipsis").frame(width:44,height:44).contentShape(Rectangle())
                                }.accessibilityLabel("项目更多操作")
                            }
                        }.padding(14).background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:22))
                    }
                }
                if model.projects.isEmpty {
                    ContentUnavailableView("还没有项目",systemImage:"film.stack",description:Text("从下方导入一段舞蹈视频开始吧。"))
                        .frame(maxWidth:.infinity)
                }
                StudioTextButton(title:"体验演示流程",fillsWidth:false) {model.startDemo()}.font(.subheadline).accessibilityIdentifier("startDemo")
            }.frame(maxWidth:900).padding(28).frame(maxWidth:.infinity)
        }
    }
    #if targetEnvironment(macCatalyst)
    private var desktopLibrary:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:28) {
                HStack(spacing:10) {
                    BrandLogo(size: 36)
                    Text("直拍鸭").font(.system(size:21,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                }.padding(.top,8)
                VStack(alignment:.leading,spacing:8) {
                    Text("工作空间").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary).padding(.leading,10)
                    Label("所有项目",systemImage:"square.grid.2x2").font(.system(size:13,weight:.medium))
                        .frame(maxWidth:.infinity,alignment:.leading).padding(12)
                        .background(.white.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                }
                Spacer()
                Button("设置",systemImage:"gearshape") {showingSettings=true}
                    .buttonStyle(.automatic)
                    .accessibilityIdentifier("openSettings")
                Button {model.showGuide=true} label: {Label("使用指南",systemImage:"questionmark.circle").frame(minHeight:44).contentShape(Rectangle())}
                    .buttonStyle(.plain).font(.system(size:12)).foregroundStyle(.secondary)
                StudioTextButton(title:"体验演示",fillsWidth:false) {model.startDemo()}.buttonStyle(.plain).font(.system(size:12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("startDemo")
                Divider()
                Label("本机处理 · 原片不上传",systemImage:"lock.shield").font(.system(size:10)).foregroundStyle(.secondary)
            }.padding(20).frame(width:194).background(DesktopPalette.panel)
            Divider()
            VStack(alignment:.leading,spacing:24) {
                HStack(alignment:.center) {
                    VStack(alignment:.leading,spacing:7) {
                        Text("这一次，你是主角").font(.system(size:26,weight:.semibold))
                        Text("将群舞变成你的个人直拍").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {importingFile=true} label: {Label(model.importing ? "正在导入…" : "导入视频",systemImage:"plus")}
                        .buttonStyle(DesktopButtonStyle(prominent:true)).keyboardShortcut("o",modifiers:.command)
                        .disabled(model.importing).accessibilityIdentifier("importVideoFile")
                }
                HStack(spacing:18) {
                    Image(systemName:"person.crop.rectangle.stack").font(.system(size:30,weight:.light)).foregroundStyle(Color.acAccent)
                        .frame(width:64,height:64).background(Color.acAccent.opacity(0.08),in:RoundedRectangle(cornerRadius:14))
                    VStack(alignment:.leading,spacing:6) {
                        Text("从一段视频开始").font(.system(size:16,weight:.semibold))
                        Text("选择主角、调整构图，自动生成跟随视频。").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:8)
                    PhotosPicker(selection:$selection,matching:.videos,photoLibrary:.shared()) {Label("从照片选择",systemImage:"photo.on.rectangle")}
                        .buttonStyle(DesktopButtonStyle()).disabled(model.importing)
                }.padding(20).background(DesktopPalette.panel,in:RoundedRectangle(cornerRadius:14))
                    .overlay {RoundedRectangle(cornerRadius:14).stroke(DesktopPalette.border,lineWidth:1)}
                HStack {
                    Text("最近项目").font(.system(size:14,weight:.semibold))
                    Text("\(model.projects.count)").font(.system(size:11)).foregroundStyle(.secondary)
                    Spacer()
                    Label("编辑自动保存",systemImage:"checkmark.icloud").font(.system(size:11)).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:240,maximum:360),spacing:18)],alignment:.leading,spacing:18) {
                        ForEach(model.projects) {project in
                            VStack(alignment:.leading,spacing:0) {
                                Button {model.open(project)} label: {
                                    ProjectThumbnail(project:project,width:nil,height:150)
                                        .overlay(alignment:.bottomLeading) {
                                            Text(project.metadata.duration.videoTime).font(.system(size:10,design:.monospaced))
                                                .padding(6).background(.black.opacity(0.7),in:RoundedRectangle(cornerRadius:5)).padding(10)
                                        }
                                }.buttonStyle(.plain).accessibilityIdentifier("openProject-\(project.id)")
                                HStack(spacing:8) {
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(project.title).font(.system(size:13,weight:.medium)).lineLimit(1)
                                        Text(project.historyStatus).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength:0)
                                    Menu {Button("删除项目",systemImage:"trash",role:.destructive) {pendingDelete=project}} label: {
                                        Image(systemName:"ellipsis").frame(width:28,height:28).contentShape(Rectangle())
                                    }.accessibilityLabel("项目更多操作")
                                }.padding(14)
                            }.background(DesktopPalette.panel,in:RoundedRectangle(cornerRadius:12))
                                .clipShape(RoundedRectangle(cornerRadius:12))
                                .overlay {RoundedRectangle(cornerRadius:12).stroke(DesktopPalette.border,lineWidth:1)}
                        }
                    }
                    if model.projects.isEmpty {
                        ContentUnavailableView("还没有项目",systemImage:"film.stack",description:Text("导入一段视频，开始第一次创作。"))
                            .frame(maxWidth:.infinity).padding(.top,30)
                    }
                }
            }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        }.background(DesktopPalette.background).foregroundStyle(.white)
            .toolbar(.hidden,for:.navigationBar)
    }
    #endif

}

/// Native List swipe actions own horizontal gesture arbitration and row lifecycle.
private struct RecentProjectRow:View {
    let project:VideoProject
    let onOpen:() -> Void
    var body:some View {
        HStack(spacing:0) {
            Button(action:onOpen) {
                HStack(spacing:12) {
                    ProjectThumbnail(project:project)
                    VStack(alignment:.leading,spacing:5) {
                        Text(project.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        Text("\(project.metadata.duration.videoTime) · \(project.historyStatus)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength:4)
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("openProject-\(project.id)")
        }.padding(12).background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:18))
            .overlay { RoundedRectangle(cornerRadius:18).stroke(.white.opacity(0.06),lineWidth:0.5) }
            .accessibilityIdentifier("projectRow-\(project.id)")
    }
}

private struct ProjectThumbnail:View {
    let project:VideoProject
    var width:CGFloat?=64
    var height:CGFloat=64
    @State private var image:UIImage?
    var body:some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.04)
                if let image { Image(uiImage:image).resizable().scaledToFill() }
                else { Image(systemName:"film").foregroundStyle(.secondary) }
            }
            .frame(width:width ?? geometry.size.width,height:height)
            .clipped().clipShape(RoundedRectangle(cornerRadius:12))
        }.frame(width:width,height:height)
            .task(id:project.id) {
                guard let url=ProjectStore.shared.sourceURL(for:project) else { return }
                image=await MediaService.shared.thumbnails(url:url,duration:project.metadata.duration,count:1,maximumSize:width == nil ? CGSize(width:960,height:540) : CGSize(width:192,height:192)).first
            }
    }
}
