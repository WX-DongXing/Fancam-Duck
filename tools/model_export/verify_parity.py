import argparse
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument("image",type=Path);image_path=parser.parse_args().image
import torch,numpy as np,coremltools as ct
from PIL import Image
from ultralytics import YOLO
torch.set_num_threads(4)
original=Image.open(image_path).convert('RGB')
scale=min(640/original.width,640/original.height)
w,h=round(original.width*scale),round(original.height*scale)
left,top=round((640-w)/2-.1),round((640-h)/2-.1)
canvas=Image.new('RGB',(640,640),(114,114,114));canvas.paste(original.resize((w,h)),(left,top))
m=YOLO('tools/model_export/weights/yolo26s-pose.pt').model.eval().fuse()
for module in m.modules():
 if hasattr(module,'end2end'): module.end2end=False
 if hasattr(module,'export'): module.export=True
with torch.no_grad():
 y=m(torch.from_numpy(np.asarray(canvas).copy()).permute(2,0,1).unsqueeze(0).float()/255)
 if isinstance(y,(tuple,list)):y=y[0]
a=y.numpy(); b=list(ct.models.MLModel('Fancam Duck/Models/YOLO26sPose.mlpackage').predict({'image':canvas}).values())[0]
i=a[0,4].argsort()[-5:]
print('PARITY',a.shape,b.shape,'pytorch top',a[0,4,i],'coreml same',b[0,4,i], 'boxes',a[0,:4,i],b[0,:4,i])
import importlib.util
spec=importlib.util.spec_from_file_location('osnet','tools/reference/osnet/osnet.py'); osnet=importlib.util.module_from_spec(spec);spec.loader.exec_module(osnet)
from pathlib import Path
state=torch.load(next(Path('tools/model_export/weights').glob('*msmt17*.pth')),weights_only=True,map_location='cpu')
net=osnet.osnet_x0_25(num_classes=state['classifier.weight'].shape[0],pretrained=False).eval();net.load_state_dict(state)
cx,cy,bw,bh=a[0,:4,a[0,4].argmax()]
roi=((cx-bw/2-left)/scale,(cy-bh/2-top)/scale,(cx+bw/2-left)/scale,(cy+bh/2-top)/scale)
person=original.crop(roi).resize((128,256))
x=torch.tensor(np.array(person).copy()).permute(2,0,1).unsqueeze(0).float()/255
with torch.no_grad(): a=torch.nn.functional.normalize(net((x-torch.tensor([.485,.456,.406]).view(1,3,1,1))/torch.tensor([.229,.224,.225]).view(1,3,1,1)),dim=1).numpy().ravel()
b=ct.models.MLModel('Fancam Duck/Models/OSNetX025.mlpackage').predict({'image':person})['embedding'].ravel().astype('float32');b/=np.linalg.norm(b)
print('OSNET_PARITY cosine=',np.dot(a,b),'max_abs_error=',np.max(np.abs(a-b)))
