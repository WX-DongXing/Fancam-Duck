import SwiftUI
import AVFoundation

struct OverlapPerson:Identifiable {
    let id:Int
    let number:Int
    let body:NormalizedRect
}

enum OverlapSelection {
    static func candidates(_ people:[OverlapPerson])->[OverlapPerson] {
        people.filter {person in
            guard person.body.isValid else {return false}
            return people.contains {other in
                guard other.id != person.id,other.body.isValid else {return false}
                let overlap=person.body.cgRect.intersection(other.body.cgRect)
                let area=min(person.body.width*person.body.height,other.body.width*other.body.height)
                return !overlap.isNull && overlap.width*overlap.height/area>0.5
            }
        }
    }
}

/// A single current frame is shared by every card; selecting a card reuses the existing detection.
struct OverlappingPeoplePicker:View {
    let people:[OverlapPerson]
    let projectID:UUID
    let source:URL?
    let sourceSize:CGSize
    let time:Double
    let demo:Bool
    let preview:CGImage?
    let selected:NormalizedRect?
    let onSelect:(NormalizedRect)->Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var frame:CGImage?
    @State private var loaded:Request?
    @State private var failed:Request?
    private struct Request:Hashable {let project:UUID;let source:URL?;let time:Double;let active:Bool;let hasPreview:Bool}
    private var request:Request {.init(project:projectID,source:source,time:time,active:scenePhase == .active,hasPreview:preview != nil)}
    var body:some View {
        ViewThatFits(in:.horizontal) {
            thumbnails
            ScrollView(.horizontal,showsIndicators:false) {thumbnails}
        }.frame(height:60)
            .accessibilityElement(children:.contain).accessibilityIdentifier("overlappingPeoplePicker")
            .task(id:request) {
                let key=request
                frame=nil;loaded=nil;failed=nil
                guard key.active,!demo,preview == nil,let source=key.source else {return}
                let generator=AVAssetImageGenerator(asset:AVURLAsset(url:source))
                generator.appliesPreferredTrackTransform=true
                generator.maximumSize=CGSize(width:1280,height:1280)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                do {
                    let result=try await withTaskCancellationHandler {
                        try await generator.image(at:CMTime(seconds:key.time,preferredTimescale:60000))
                    } onCancel: {generator.cancelAllCGImageGeneration()}
                    guard !Task.isCancelled else {return}
                    frame=result.image;loaded=key
                } catch {
                    guard !Task.isCancelled else {return}
                    failed=key
                }
            }
    }
    private var thumbnails:some View {
        HStack(spacing:12) {
            ForEach(people) {person in
                let chosen=selected == person.body
                Button {onSelect(person.body)} label: {
                    thumbnail(person.body)
                        .frame(width:46,height:56).clipped()
                        .clipShape(RoundedRectangle(cornerRadius:6))
                        .overlay {RoundedRectangle(cornerRadius:6).stroke(chosen ? Color.acAccent : .white.opacity(0.4),lineWidth:chosen ? 2 : 1)}
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("选择重叠人物 \(person.number+1)")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityIdentifier("overlapPerson-\(person.id)")
            }
        }.padding(2)
    }
    private func thumbnail(_ body:NormalizedRect)->some View {
        GeometryReader {geometry in
            let crop=body.cgRect.insetBy(dx:-body.width*0.12,dy:-body.height*0.08).intersection(CGRect(x:0,y:0,width:1,height:1))
            let scale=max(geometry.size.width/max(1,sourceSize.width*crop.width),geometry.size.height/max(1,sourceSize.height*crop.height))
            let image=preview ?? (loaded == request ? frame : nil)
            ZStack {
                Color.black
                if demo || image != nil {
                    Group {
                        if demo {DemoStage(time:time,target:nil)}
                        else if let image {Image(decorative:image,scale:1).resizable()}
                    }
                    .frame(width:sourceSize.width*scale,height:sourceSize.height*scale)
                    .position(x:geometry.size.width/2+(0.5-crop.midX)*sourceSize.width*scale,
                              y:(0.5-crop.minY)*sourceSize.height*scale)
                } else if failed == request || source == nil {
                    Image(systemName:"person.crop.rectangle").font(.title3).foregroundStyle(.secondary)
                } else {ProgressView().tint(.white)}
            }.frame(width:geometry.size.width,height:geometry.size.height)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
