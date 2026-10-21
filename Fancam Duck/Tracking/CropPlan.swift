import Foundation

struct CropPlan {
    struct Frame:Codable,Sendable { let time:Double; var rect:CGRect }
    /// A steady lens: constant zoom and vertical framing; only pan when the dancer needs room.
    /// Solve a bounded camera path with velocity and acceleration penalties, independently of detections.
    static func make(samples:[TargetSample],source:CGSize,settings:EditSettings) -> [Frame] {
        guard !Task.isCancelled else {return []}
        var unique:[Int:TargetSample]=[:]
        for s in samples where s.time.isFinite && s.body.isValid { unique[Int((s.time*10000).rounded())]=s }
        let sorted=unique.values.sorted { $0.time<$1.time }
        guard !sorted.isEmpty,source.width>0,source.height>0 else { return [] }
        if let anchor=settings.compositionAnchor,anchor.isValid,
           anchor.time>=sorted.first!.time-0.0001,anchor.time<=sorted.last!.time+0.0001 {
            return anchored(samples:sorted,source:source,settings:settings,anchor:anchor)
        }
        let bodies=sorted.map { (settings.protectFullBody ? ($0.protection ?? $0.body) : $0.body).cgRect }
        let desired=sorted.map { source.height*$0.body.height/max(0.1,settings.personHeight) }.sorted()
        let maxHeight=min(source.height,source.width/settings.aspectRatio.value)
        var height=desired[min(desired.count-1,Int(Double(desired.count-1)*0.8))]
        let top=bodies.map { $0.minY*source.height }.min()!,bottom=bodies.map { $0.maxY*source.height }.max()!
        let protectedHeight=max((bottom-top)*1.10,bodies.map { $0.width*source.width/settings.aspectRatio.value*1.10 }.max()!)
        if settings.protectFullBody {
            // Reserve room for the whole sequence of jumps and extended limbs, without zoom pumping.
            height=max(height,(bottom-top)*1.10,bodies.map { $0.width*source.width/settings.aspectRatio.value*1.10 }.max()!)
        }
        height=min(maxHeight,max(2,height)) / max(0.1,settings.compositionScale)
        if settings.protectFullBody { height=max(height,min(maxHeight,protectedHeight)) }
        height=min(maxHeight,max(min(120,maxHeight),height));let width=height*settings.aspectRatio.value
        var minY=height/2,maxY=source.height-height/2
        if settings.protectFullBody,bottom-top<=height {
            minY=max(minY,bottom-height/2);maxY=min(maxY,top+height/2)
        }
        let cy=min(maxY,max(minY,(top+bottom)/2-settings.compositionY*height))
        let focus=sorted.map { ($0.focusX ?? $0.body.center.x)*source.width+settings.horizontalOffset*source.width-settings.compositionX*width }
        let neutral=focus.sorted()[focus.count/2]
        let deadZone=width*0.12
        let preferred=focus.map { min($0+deadZone,max($0-deadZone,neutral)) / source.width }
        var lower=Array(repeating:width/2/source.width,count:sorted.count)
        var upper=Array(repeating:1-width/2/source.width,count:sorted.count)
        if settings.protectFullBody {
            for i in sorted.indices {
                let l=max(width/2,bodies[i].maxX*source.width-width/2+width*0.025)
                let u=min(source.width-width/2,bodies[i].minX*source.width+width/2-width*0.025)
                if l<=u { lower[i]=l/source.width;upper[i]=u/source.width }
                else {
                    let requiredL=max(width/2,bodies[i].maxX*source.width-width/2)
                    let requiredU=min(source.width-width/2,bodies[i].minX*source.width+width/2)
                    if requiredL<=requiredU {lower[i]=requiredL/source.width;upper[i]=requiredU/source.width}
                }
            }
        }
        let velocity:Double=settings.followSpeed == .gentle ? 100 : settings.followSpeed == .standard ? 50 : 18
        let acceleration:Double=settings.followSpeed == .gentle ? 1200 : settings.followSpeed == .standard ? 500 : 150
        let x=solve(times:sorted.map(\.time),preferred:preferred,lower:lower,upper:upper,velocity:velocity,acceleration:acceleration,jerk:settings.followSpeed == .gentle ? 6000 : settings.followSpeed == .standard ? 3000 : 600)
        guard x.count==sorted.count else {return []}
        return sorted.indices.map { i in Frame(time:sorted[i].time,rect:CGRect(x:x[i]*source.width-width/2,y:cy-height/2,width:width,height:height)) }
    }
    /// Preserve the chosen lens and reference-frame placement even when later poses
    /// change the automatic size estimate. Only horizontal following is optimized.
    private static func anchored(samples:[TargetSample],source:CGSize,settings:EditSettings,anchor:CompositionAnchor) -> [Frame] {
        var samples=samples
        let before=samples.last {$0.time<=anchor.time} ?? samples[0]
        let after=samples.first {$0.time>=anchor.time} ?? samples.last!
        let u=after.time>before.time ? min(1,max(0,(anchor.time-before.time)/(after.time-before.time))) : 0
        let referenceFocus=(before.focusX ?? before.body.center.x)*(1-u)+(after.focusX ?? after.body.center.x)*u
        // Insert an exact reference-time knot so a non-10Hz selection cannot drift.
        samples.removeAll {abs($0.time-anchor.time)<0.0001}
        samples.append(.init(time:anchor.time,body:before.body,focusX:referenceFocus))
        samples.sort {$0.time<$1.time}
        let height=min(min(source.height,source.width/settings.aspectRatio.value),anchor.crop.height*source.height)
        let width=height*settings.aspectRatio.value
        let cx=min(source.width-width/2,max(width/2,anchor.crop.center.x*source.width))
        let cy=min(source.height-height/2,max(height/2,anchor.crop.center.y*source.height))
        let focus=samples.map { cx+(($0.focusX ?? $0.body.center.x)-referenceFocus)*source.width }
        let preferred=focus.map {min($0+width*0.12,max($0-width*0.12,cx))/source.width}
        var lower=Array(repeating:width/2/source.width,count:samples.count)
        var upper=Array(repeating:1-width/2/source.width,count:samples.count)
        for i in samples.indices {
            if abs(samples[i].time-anchor.time)<0.0001 {
                // Explicit composition has priority over automatic full-body padding.
                lower[i]=cx/source.width;upper[i]=lower[i]
            }
        }
        let gentle=settings.followSpeed == .gentle,standard=settings.followSpeed == .standard
        let x=solve(times:samples.map(\.time),preferred:preferred,lower:lower,upper:upper,
                    velocity:gentle ? 100 : standard ? 50 : 18,
                    acceleration:gentle ? 1200 : standard ? 500 : 150,
                    jerk:gentle ? 6000 : standard ? 3000 : 600)
        guard x.count==samples.count else {return []}
        return samples.indices.map {.init(time:samples[$0].time,rect:.init(x:x[$0]*source.width-width/2,y:cy-height/2,width:width,height:height))}
    }
    static func clipped(_ frames:[Frame],start:Double,end:Double) -> [Frame] {
        guard end>start,let first=rect(at:start,in:frames),let last=rect(at:end,in:frames) else {return []}
        return [.init(time:start,rect:first)]+frames.filter {$0.time>start && $0.time<end}+[.init(time:end,rect:last)]
    }
    static func rect(at time:Double,in frames:[Frame]) -> CGRect? {
        guard let first=frames.first,let last=frames.last else { return nil }
        if time<=first.time { return first.rect };if time>=last.time { return last.rect }
        var lo=0,hi=frames.count-1
        while hi-lo>1 { let mid=(lo+hi)/2;if frames[mid].time<=time {lo=mid} else {hi=mid} }
        let a=frames[lo],b=frames[hi],u=(time-a.time)/(b.time-a.time)
        return CGRect(x:a.rect.minX+(b.rect.minX-a.rect.minX)*u,y:a.rect.minY+(b.rect.minY-a.rect.minY)*u,width:a.rect.width,height:a.rect.height)
    }
    /// Banded quadratic with velocity, acceleration and jerk costs. ADMM separates
    /// the box constraints from an O(n) Cholesky solve; factorization is reused.
    private static func solve(times:[Double],preferred:[Double],lower:[Double],upper:[Double],velocity:Double,acceleration:Double,jerk:Double) -> [Double] {
        let n=preferred.count,band=4,rho=20.0
        var matrix=Array(repeating:0.0,count:n*band)
        for i in 0..<n { matrix[i*band]=1+rho }
        func add(_ start:Int,_ coefficients:[Double],_ weight:Double) {
            for a in coefficients.indices { for b in 0...a {
                matrix[(start+a)*band+a-b]+=weight*coefficients[a]*coefficients[b]
            } }
        }
        if n>1 { for i in 0..<n-1 {
            let dt=max(0.05,(times[i+1]-times[i])/0.1)
            add(i,[-1/dt,1/dt],velocity)
        } }
        var second:[[Double]]=[]
        if n>2 { for i in 0..<n-2 {
            let a=max(0.05,(times[i+1]-times[i])/0.1),b=max(0.05,(times[i+2]-times[i+1])/0.1)
            let factor=2/(a+b),c=[factor/a,-factor*(1/a+1/b),factor/b]
            second.append(c);add(i,c,acceleration)
        } }
        if n>3 { for i in 0..<n-3 {
            let dt=max(0.05,(times[i+3]-times[i])/0.3),a=second[i],b=second[i+1]
            add(i,[-a[0]/dt,(b[0]-a[1])/dt,(b[1]-a[2])/dt,b[2]/dt],jerk)
        } }
        // Store the lower Cholesky factor by diagonal offset (0...3).
        var factor=Array(repeating:0.0,count:n*band)
        for i in 0..<n { for j in max(0,i-3)...i {
            var value=matrix[i*band+i-j]
            if j>max(0,i-3) { for k in max(0,i-3)..<j { value-=factor[i*band+i-k]*factor[j*band+j-k] } }
            factor[i*band+i-j] = i==j ? sqrt(max(1e-12,value)) : value/factor[j*band]
        } }
        var z=preferred.indices.map { min(upper[$0],max(lower[$0],preferred[$0])) }
        var dual=Array(repeating:0.0,count:n),x=dual,y=dual
        for _ in 0..<600 {
            if Task.isCancelled {return []}
            for i in 0..<n {
                var rhs=preferred[i]+rho*(z[i]-dual[i])
                if i>0 { for k in max(0,i-3)..<i { rhs-=factor[i*band+i-k]*y[k] } }
                y[i]=rhs/factor[i*band]
            }
            for i in (0..<n).reversed() {
                var rhs=y[i]
                if i+1<n { for k in i+1...min(n-1,i+3) { rhs-=factor[k*band+k-i]*x[k] } }
                x[i]=rhs/factor[i*band]
            }
            var residual=0.0
            for i in 0..<n {
                let previous=z[i]
                z[i]=min(upper[i],max(lower[i],x[i]+dual[i]));dual[i]+=x[i]-z[i]
                residual=max(residual,abs(x[i]-z[i]),abs(z[i]-previous))
            }
            if residual<1e-8 { break }
        }
        return z
    }

    /// Monotone cubic interpolation at rendered frame times removes 10Hz velocity
    /// corners without overshooting adjacent positions or the source boundaries.
    static func renderFrames(_ plan:[Frame],frameRate:Double,preserving time:Double?=nil) -> [Frame] {
        guard !Task.isCancelled else {return []}
        guard plan.count>2,frameRate.isFinite,frameRate>0 else { return plan }
        let times=plan.map(\.time),centers=plan.map {Double($0.rect.midX)}
        let slopes=(1..<plan.count).map {(centers[$0]-centers[$0-1])/(times[$0]-times[$0-1])}
        var tangent=Array(repeating:0.0,count:plan.count)
        tangent[0]=slopes[0];tangent[plan.count-1]=slopes.last!
        for i in 1..<plan.count-1 where slopes[i-1]*slopes[i]>0 {
            let a=times[i]-times[i-1],b=times[i+1]-times[i],w1=2*b+a,w2=b+2*a
            tangent[i]=(w1+w2)/(w1/slopes[i-1]+w2/slopes[i])
        }
        var rendered:[Frame]=[],index=0
        let start=times[0],end=times.last!,step=1/min(60,frameRate)
        // Avoid an extra near-zero tail interval when the duration is a frame multiple
        // plus floating-point roundoff (e.g. 0.6000000000000001 seconds at 25fps).
        let count=Int(ceil((end-start)/step-1e-9))
        var renderTimes=(0...count).map {$0==count ? end : min(end,start+Double($0)*step)}
        if let time,time>=start,time<=end {
            renderTimes.removeAll {abs($0-time)<1e-8}
            renderTimes.append(time);renderTimes.sort()
        }
        for time in renderTimes {
            if Task.isCancelled {return []}
            while index+1<plan.count-1 && times[index+1]<time { index+=1 }
            let dt=times[index+1]-times[index],u=min(1,max(0,(time-times[index])/dt))
            let a=centers[index],b=centers[index+1],u2=u*u,u3=u2*u
            let center=(2*u3-3*u2+1)*a+(u3-2*u2+u)*dt*tangent[index]+(-2*u3+3*u2)*b+(u3-u2)*dt*tangent[index+1]
            var rect=plan[index].rect
            rect.origin.x=min(max(a,b),max(min(a,b),center))-rect.width/2
            rendered.append(.init(time:time,rect:rect))
        }
        return rendered
    }
}
