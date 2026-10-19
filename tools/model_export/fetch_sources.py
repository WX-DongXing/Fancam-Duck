from pathlib import Path
from urllib.request import urlopen
from urllib.parse import quote
import json

root = Path(__file__).resolve().parents[1] / 'reference'
def fetch(url, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with urlopen(url, timeout=120) as response:
        path.write_bytes(response.read())
    print(path, path.stat().st_size)
commit = 'ee7f1c5fcbdcac48ed8bfab38d52c0006bf304da'
for filename in ['utils.py', 'kalman_filter.py']:
    fetch('https://raw.githubusercontent.com/kamkyu94/TrackTrack/' + commit + '/' + quote('3. Tracker/trackers/' + filename), root / 'tracktrack' / filename)
for filename in ['LICENSE','README.md']:
    fetch('https://raw.githubusercontent.com/kamkyu94/TrackTrack/' + commit + '/' + filename, root / 'tracktrack' / filename)
for filename in ['torchreid/models/osnet.py','LICENSE','docs/MODEL_ZOO.md']:
    fetch('https://raw.githubusercontent.com/KaiyangZhou/deep-person-reid/master/' + filename, root / 'osnet' / Path(filename).name)
fetch('https://huggingface.co/api/models/kaiyangzhou/osnet/tree/main', root / 'osnet-tree.json')
