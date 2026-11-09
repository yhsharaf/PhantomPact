# Contact sheet of numbered screenshots: sheet.py <shots dir> <prefix> <out.jpg> [cols] [width]
# Takes <prefix>-NN.png in order, a label in the corner of each (its name's tail).
import sys, glob, os, re
from PIL import Image, ImageDraw

d, prefix, out = sys.argv[1], sys.argv[2], sys.argv[3]
cols = int(sys.argv[4]) if len(sys.argv) > 4 else 4
cw = int(sys.argv[5]) if len(sys.argv) > 5 else 480
files = sorted(glob.glob(os.path.join(d, prefix + '-*.png')))
if not files:
    print('no shots for', prefix)
    sys.exit(0)
ims = [Image.open(f).convert('RGB') for f in files]
w, h = ims[0].size
ch = int(h * cw / w)
rows = (len(ims) + cols - 1) // cols
S = Image.new('RGB', (cw * cols, ch * rows), (20, 20, 20))
for k, (f, im) in enumerate(zip(files, ims)):
    im = im.resize((cw, ch))
    dr = ImageDraw.Draw(im)
    tag = re.sub(r'\.png$', '', os.path.basename(f))[len(prefix) + 1:]
    dr.rectangle([0, 0, 8 + 7 * len(tag), 14], fill=(0, 0, 0))
    dr.text((3, 1), tag, fill=(255, 255, 0))
    S.paste(im, ((k % cols) * cw, (k // cols) * ch))
S.save(out, quality=85)
print('sheet', out, S.size, len(ims), 'frames')
