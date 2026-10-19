"""Compare identical desktop runs on the rendered frame grid, not differently sampled derivatives."""
import argparse,json,subprocess,shutil,hashlib
from pathlib import Path
import numpy as np
parser=argparse.ArgumentParser();parser.add_argument('directory',type=Path);args=parser.parse_args();root=args.directory
before=json.loads((root/'before/report.json').read_text());after=json.loads((root/'after/report.json').read_text())
assert before['source']==after['source'], 'Source metadata must match'
assert before['output']==after['output'], 'Output settings must match'

def unique(samples):
    return sorted({round(s['time'],4):s for s in samples}.values(),key=lambda s:s['time'])
old=unique(json.loads((root/'before/trajectory.json').read_text()));new=unique(json.loads((root/'after/trajectory.json').read_text()))
assert [round(s['time'],4) for s in old]==[round(s['time'],4) for s in new]
def iou(a,b):
    overlap=max(0,min(a['x']+a['width'],b['x']+b['width'])-max(a['x'],b['x']))*max(0,min(a['y']+a['height'],b['y']+b['height'])-max(a['y'],b['y']))
    return overlap/(a['width']*a['height']+b['width']*b['height']-overlap)
# Exclude the fractional last step when differentiating, using one uniform source-frame grid.
t=np.arange(0,before['source']['duration']-1e-8,1/25)
def interpolate(path):
    ts=np.array([s['time'] for s in path]);r=np.array([s['rect'] for s in path]);x=r[:,0,0]+r[:,1,0]/2
    return np.interp(t,ts,x),np.interp(t,ts,r[:,1,1]),np.interp(t,ts,r[:,0,1]+r[:,1,1]/2)
def motion(path):
    x,h,y=interpolate(path);v=np.diff(x)*25;a=np.diff(v)*25;j=np.diff(a)*25
    return {'rms_velocity_source_pixels_per_second':float(np.sqrt(np.mean(v*v))),'rms_acceleration_source_pixels_per_second_squared':float(np.sqrt(np.mean(a*a))),'max_acceleration':float(abs(a).max()),'rms_jerk_source_pixels_per_second_cubed':float(np.sqrt(np.mean(j*j))),'zoom_height_range':float(np.ptp(h)),'vertical_center_range':float(np.ptp(y)),'horizontal_travel_range':float(np.ptp(x))}
oldpath=json.loads((root/'before/camera.json').read_text());newpath=json.loads((root/'after/rendered-camera.json').read_text())
report={'method':'Same source, target anchor, 10Hz analysis, 75% person size, standard follow, full-body protection, 1080x1920 25fps; sequential Debug CPU-only simulator runs. Rendered motion compared on uniform 25fps grid.','before':before,'after':after,'analysis_reduction_percent':100*(1-after['analysisSeconds']/before['analysisSeconds']),'reid_call_reduction_percent':100*(1-after['metrics']['reidCalls']/before['metrics']['reidCalls']),'trajectory_comparison':{'unique_samples':len(old),'minimum_body_iou':min(iou(a['body'],b['body']) for a,b in zip(old,new)),'mean_body_iou':float(np.mean([iou(a['body'],b['body']) for a,b in zip(old,new)])),'max_center_x_change_source_pixels':max(abs(a['body']['x']+a['body']['width']/2-b['body']['x']-b['body']['width']/2)*3840 for a,b in zip(old,new))},'motion_before':motion(oldpath),'motion_after':motion(newpath),'limitations':['Single video is regression evidence, not aggregate accuracy.','M4 simulator CPU timing is not physical iPhone throughput.','Motion derivatives are camera-path metrics, not a subjective dizziness score.']}
for name in ['rms_acceleration_source_pixels_per_second_squared','rms_jerk_source_pixels_per_second_cubed']:
    report[name+'_reduction_percent']=100*(1-report['motion_after'][name]/report['motion_before'][name])
# Check full-body/source constraints against the render path at all sampled input times.
times=np.array([s['time'] for s in newpath]);rects=np.array([s['rect'] for s in newpath]);violations=[]
for s in new:
    rect=np.array([[np.interp(s['time'],times,rects[:,i,j]) for j in range(2)] for i in range(2)])
    b=s.get('protection',s['body']);left=b['x']*3840;right=(b['x']+b['width'])*3840;top=b['y']*2160;bottom=(b['y']+b['height'])*2160
    clipped=max(rect[0,0]-left,right-rect[0,0]-rect[1,0],rect[0,1]-top,bottom-rect[0,1]-rect[1,1],0)
    if clipped>1:violations.append({'time':s['time'],'source_pixels':float(clipped)})
report['sampled_full_body_clip_over_one_pixel']=violations
original=Path('models-validation/desktop-dance.mp4')
if original.exists():
    with original.open('rb') as f: report['source_sha256']=hashlib.file_digest(f,'sha256').hexdigest()
ffmpeg=shutil.which('ffmpeg')
if ffmpeg:
    hashes=[]
    for label in ['before','after']:
        result=subprocess.run([ffmpeg,'-v','error','-i',str(root/label/'output.mp4'),'-map','0:a:0','-c','copy','-f','hash','-hash','sha256','-'],capture_output=True,text=True,check=True)
        hashes.append(result.stdout.strip().split('=',1)[1])
    report['audio_stream_hash_equal']=hashes[0]==hashes[1]
    report['audio_stream_sha256']=hashes[1]
ffprobe=shutil.which('ffprobe')
if ffprobe:
    result=subprocess.run([ffprobe,'-v','error','-show_entries','stream=codec_type,duration','-of','json',str(root/'after/output.mp4')],capture_output=True,text=True,check=True)
    for stream in json.loads(result.stdout)['streams']:
        report['output_'+stream['codec_type']+'_duration_seconds']=float(stream['duration'])
(root/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
