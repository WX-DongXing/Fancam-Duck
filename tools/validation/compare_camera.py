"""Recompute the previous planner on the same real observations, then compare camera motion."""
import argparse,json
from pathlib import Path
import numpy as np
parser=argparse.ArgumentParser();parser.add_argument('directory',type=Path);parser.add_argument('--width',type=float,default=3840);parser.add_argument('--height',type=float,default=2160)
args=parser.parse_args();root=args.directory;W,H=args.width,args.height
points=json.loads((root/'FancamDuck-last-trajectory.json').read_text())
points=list({round(p['time'],4):p for p in points}.values());points.sort(key=lambda p:p['time'])
new=json.loads((root/'FancamDuck-last-camera.json').read_text());crop=[]
for p in points:
 b=p.get('protection') or p['body'];h=min(H,max(2,max(H*b['height']/.75,W*b['width']*16/9)));w=h*9/16
 x=min(W-w,max(0,(b['x']+b['width']/2)*W-w/2));y=min(H-h,max(0,(b['y']+b['height']/2)*H-h/2));crop.append((x+w/2,y+h/2,h))
old=[]
for i,p in enumerate(points):
 window=crop[max(0,i-3):i+4];cx=sum(c[0] for c in window)/len(window);cy=sum(c[1] for c in window)/len(window);h=max(c[2] for c in window)
 b=p.get('protection') or p['body']
 h=max(h,2*max(abs(b['y']*H-cy),abs((b['y']+b['height'])*H-cy)))
 h=max(h,2*max(abs(b['x']*W-cx),abs((b['x']+b['width'])*W-cx))*16/9)
 h=min(h,H);w=h*9/16
 x=min(W-w,max(0,cx-w/2));y=min(H-h,max(0,cy-h/2));old.append({'time':p['time'],'rect':[[x,y],[w,h]]})
def metrics(plan):
 ts=np.array([p['time'] for p in plan]);r=np.array([p['rect'] for p in plan]);cx=r[:,0,0]+r[:,1,0]/2;cy=r[:,0,1]+r[:,1,1]/2;h=r[:,1,1];dt=np.diff(ts)
 vx=np.diff(cx)/dt;acc=np.diff(vx)/((dt[1:]+dt[:-1])/2)
 return {'zoom_height_range_pixels':float(h.max()-h.min()),'vertical_center_range_pixels':float(cy.max()-cy.min()),'max_horizontal_acceleration_source_pixels_per_second_squared':float(np.abs(acc).max()),'rms_horizontal_acceleration':float(np.sqrt(np.mean(acc**2))),'max_log_zoom_rate_per_second':float(np.max(np.abs(np.diff(np.log(h))/dt)))}
report_path=root/'comparison.json'
report=json.loads(report_path.read_text()) if report_path.exists() else {}
report.update({'comparison_note':'Previous standard-speed planner recomputed on the same new observations; source pixels, not metrics inferred from the previous encoded video.','old_camera_recomputed_on_same_new_target_samples':metrics(old),'new_camera':metrics(new)})
report_path.write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
