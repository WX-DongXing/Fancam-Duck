"""Export pinned on-device models; run inside the project's .venv on macOS."""
from pathlib import Path
import hashlib, importlib.util, json, shutil, urllib.request
import numpy as np
import torch
import coremltools as ct
import ultralytics
from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / 'tools/model_export/weights'
DEST = ROOT / 'Fancam Duck/Models'
WORK.mkdir(parents=True, exist_ok=True)
DEST.mkdir(parents=True, exist_ok=True)
torch.set_num_threads(4)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def fetch(url, path, expected=None):
    if not path.exists():
        print('Downloading', url, flush=True)
        urllib.request.urlretrieve(url, path)
    if expected and sha(path) != expected:
        raise ValueError(f'Weight checksum mismatch: {path}')
    return path

pose_path = WORK / 'yolo26s-pose.pt'
if not pose_path.exists():
    model = YOLO('yolo26s-pose.pt')
    shutil.move('yolo26s-pose.pt', pose_path)
pose = YOLO(str(pose_path))
pose_out = DEST / 'YOLO26sPose.mlpackage'
if not pose_out.exists():
    result = Path(pose.export(format='coreml', imgsz=640, half=True, nms=False, end2end=False, batch=1, device='cpu'))
    shutil.copytree(result, pose_out)
print('Pose exported', pose_out, flush=True)

filename = 'osnet_x0_25_msmt17_combineall_256x128_amsgrad_ep150_stp60_lr0.0015_b64_fb10_softmax_labelsmooth_flip_jitter.pth'
weights = fetch('https://huggingface.co/kaiyangzhou/osnet/resolve/main/' + filename, WORK / filename,
                'cf55163d78fc44c62c82f85ab62d39f10438679b5abe8c698ae08cfa84aa6e18')
spec = importlib.util.spec_from_file_location('osnet_source', ROOT / 'tools/reference/osnet/osnet.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
state = torch.load(weights, map_location='cpu', weights_only=True)
state = state.get('state_dict', state)
state = {k.removeprefix('module.'): v for k, v in state.items()}
net = module.osnet_x0_25(num_classes=state['classifier.weight'].shape[0], pretrained=False).eval()
net.load_state_dict(state, strict=True)

class Embedding(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
        self.register_buffer('mean', torch.tensor([.485, .456, .406]).view(1,3,1,1))
        self.register_buffer('std', torch.tensor([.229, .224, .225]).view(1,3,1,1))
    def forward(self, image):
        return torch.nn.functional.normalize(self.model((image - self.mean) / self.std), dim=1)

reid = Embedding(net).eval()
example = torch.rand(1,3,256,128)
reid_out = DEST / 'OSNetX025.mlpackage'
if not reid_out.exists():
    traced = torch.jit.trace(reid, example)
    exported = ct.convert(traced, inputs=[ct.ImageType(name='image', shape=example.shape, scale=1/255, color_layout=ct.colorlayout.RGB)],
                          outputs=[ct.TensorType(name='embedding')], compute_precision=ct.precision.FLOAT16,
                          minimum_deployment_target=ct.target.iOS18, convert_to='mlprogram')
    exported.short_description = 'OSNet x0.25 MSMT17 ReID; RGB /255 then ImageNet normalization in graph; L2-normalized 512D embedding.'
    exported.save(str(reid_out))
manifest = {
    'ultralytics': ultralytics.__version__, 'torch': torch.__version__, 'coremltools': ct.__version__,
    'pose': {'model': pose_path.name, 'sha256': sha(pose_path), 'size': [640,640], 'end2end': False, 'nms': False, 'package': pose_out.name},
    'reid': {'model': filename, 'sha256': sha(weights), 'size': [256,128], 'normalization': 'ImageNet inside graph; output L2', 'package': reid_out.name},
    'tracktrack_commit': 'ee7f1c5fcbdcac48ed8bfab38d52c0006bf304da'
}
for path in [pose_out, reid_out]:
    model = ct.models.MLModel(str(path), skip_model_load=True)
    manifest[path.stem] = {'inputs': str(model.get_spec().description.input), 'outputs': str(model.get_spec().description.output)}
(ROOT / 'Fancam Duck/Models/manifest.json').write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2), flush=True)
