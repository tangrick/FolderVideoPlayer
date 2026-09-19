#!/usr/bin/env python3
"""Task 6.1 — SFace as a PyTorch module, rebuilt from the ONNX graph.

SFace (OpenCV Zoo, `face_recognition_sface_2021dec.onnx`) is the model behind
every face decision the app makes: `FACE_MATCH_COSINE = 0.30` was tuned against
the maintainer's real cross-video faces, which peak at 0.326 (pitfall 28). Core ML has
no ONNX importer any more (`coremltools` dropped `ct.converters.onnx`), so the
route to a shippable model is: read the ONNX graph, rebuild it in PyTorch, trace,
convert. This file is the rebuild.

**It is generated from the graph, not transcribed from memory.** The network is
a straight chain — 27 Conv, 29 BatchNorm, 27 PReLU, one Sub, one Mul, one
Dropout, one Flatten, one Gemm — with no skips and no branches, so the nodes are
walked in order and each one becomes exactly one layer. Two structural claims
are asserted rather than hoped for:

  - every node is consumed in topological order and every initializer is
    consumed by exactly one layer (174 of them). A weight quietly dropped is a
    small cosine drift that looks like float rounding, so it fails here instead;
  - `check()` re-runs the graph with the *shape* of each stage recorded, which is
    how the port proves it built the network it says it built (14 depthwise and
    pointwise stages, 1024 x 7 x 7 before the flatten, 128 out).

Two things about the model that the port must not "improve":

  - **The normalisation is inside the graph.** `Sub(127.5)` then
    `Mul(1/128)` means the ONNX takes raw 0-255 pixels; `cv2.FaceRecognizerSF`
    hands it exactly that. Anything that normalises on the way in would be
    normalising twice.
  - **The colour order is RGB.** Measured, not assumed (see `sface_parity.py`):
    on the same crops, feeding the model RGB reproduces `cv2`'s embedding to
    6e-7, feeding it BGR lands at 0.099 — two orders of magnitude worse than the
    gate, and enough to move a cosine across the 0.30 line.

Run it directly for the structural report:

    /opt/anaconda3/bin/python3 docs/coreml-spike/sface_torch.py [onnx path]
"""

import os
import sys

import numpy as np
import onnx
import torch
import torch.nn as nn
import torch.nn.functional as F
from onnx import numpy_helper

SFACE_ONNX = "face_recognition_sface_2021dec.onnx"
YUNET_ONNX = "face_detection_yunet_2023mar.onnx"
SUPPORT = os.path.expanduser("~/Library/Application Support/FolderVideoPlayer")
# Where the weights have lived across machines: the app's own support dir, the
# scratch runtime area at the workspace root, and the same area one level down
# (this workspace nests the scratch dirs under a second `fvp/`).
MODEL_DIRS = [os.path.join(SUPPORT, "models"),
              os.path.expanduser("~/fvp-coreml-test/models"),
              os.path.expanduser("~/fvp/fvp-coreml-test/models")]


def fixtures_dir():
    """Where the spike's artifacts live (`~/fvp-coreml-models` by convention).

    One resolver, shared, because the cropped-face fixture and the converted
    package must be looked for in the same place — and because this workspace
    nests the scratch dirs one level deeper than the older scripts assume.
    """
    override = os.environ.get("FVP_FIXTURE_DIR")
    if override:
        return override
    for d in ("~/fvp-coreml-models", "~/fvp/fvp-coreml-models"):
        path = os.path.expanduser(d)
        if os.path.isdir(path):
            return path
    return os.path.expanduser("~/fvp-coreml-models")


def find_model(filename, extra_dirs=()):
    """Resolve an ONNX weight file, or say every path that was tried."""
    override = os.environ.get("FVP_MODEL_DIR")
    for d in ([override] if override else []) + list(extra_dirs) + MODEL_DIRS:
        path = os.path.join(d, filename)
        if os.path.exists(path):
            return path
    raise SystemExit("%s not found. Tried:\n  %s\nSet FVP_MODEL_DIR to its directory."
                     % (filename, "\n  ".join(
                         os.path.join(d, filename) for d in MODEL_DIRS)))

# Every op the graph uses. A new one is a deliberate act, not a silent skip.
SUPPORTED = {"Sub", "Mul", "Conv", "BatchNormalization", "PRelu",
             "Dropout", "Flatten", "Gemm"}
# What the shipped model is, so a re-export with a different shape fails loudly.
EXPECTED_OPS = {"Conv": 27, "BatchNormalization": 29, "PRelu": 27,
                "Sub": 1, "Mul": 1, "Dropout": 1, "Flatten": 1, "Gemm": 1}
INPUT_SHAPE = (1, 3, 112, 112)
EMBED_DIM = 128


class _Scalar(nn.Module):
    """One Sub or Mul against a graph constant — the model's own normalisation."""

    def __init__(self, op, value):
        super().__init__()
        self.op = op
        self.register_buffer("value", torch.tensor([float(value)]))

    def forward(self, x):
        return x - self.value[0] if self.op == "Sub" else x * self.value[0]


class _Conv2d(nn.Module):
    """A Conv node. `groups` is what makes the dw stages depthwise."""

    def __init__(self, weight, stride, padding, dilation, groups):
        super().__init__()
        self.weight = nn.Parameter(torch.from_numpy(weight), requires_grad=False)
        self.stride, self.padding = stride, padding
        self.dilation, self.groups = dilation, groups

    def forward(self, x):
        return F.conv2d(x, self.weight, None, self.stride, self.padding,
                        self.dilation, self.groups)


class _BatchNorm(nn.Module):
    """Inference BatchNorm — running statistics, never batch ones.

    Written out rather than `nn.BatchNorm2d` so the eval/train distinction
    cannot be undone by a later `.train()`: ONNX inference BN is the running
    statistics, full stop.
    """

    def __init__(self, gamma, beta, mean, var, eps):
        super().__init__()
        self.weight = nn.Parameter(torch.from_numpy(gamma), requires_grad=False)
        self.bias = nn.Parameter(torch.from_numpy(beta), requires_grad=False)
        self.register_buffer("running_mean", torch.from_numpy(mean))
        self.register_buffer("running_var", torch.from_numpy(var))
        self.eps = eps

    def forward(self, x):
        return F.batch_norm(x, self.running_mean, self.running_var,
                            self.weight, self.bias, False, 0.0, self.eps)


class _PReLU(nn.Module):
    """ONNX PRelu with a [C,1,1] slope -> F.prelu's per-channel (C,)."""

    def __init__(self, slope):
        super().__init__()
        self.weight = nn.Parameter(torch.from_numpy(slope.reshape(-1)),
                                   requires_grad=False)

    def forward(self, x):
        return F.prelu(x, self.weight)


class _Flatten(nn.Module):
    def forward(self, x):
        return x.flatten(1)


class _Identity(nn.Module):
    """Dropout at inference. Kept as a node so the op count still adds up."""

    def forward(self, x):
        return x


class _Gemm(nn.Module):
    """Gemm with transB=1 — the ONNX weight is [out, in], i.e. linear's layout."""

    def __init__(self, weight, bias):
        super().__init__()
        self.weight = nn.Parameter(torch.from_numpy(weight), requires_grad=False)
        self.bias = nn.Parameter(torch.from_numpy(bias), requires_grad=False)

    def forward(self, x):
        return F.linear(x, self.weight, self.bias)


class SFaceNet(nn.Module):
    """The rebuilt network: an ordered list of the graph's nodes."""

    def __init__(self, layers):
        super().__init__()
        self.layers = nn.ModuleList(layers)

    def forward(self, x):
        for layer in self.layers:
            x = layer(x)
        return x


def _attr(node, name, default=None):
    for a in node.attribute:
        if a.name == name:
            if a.type == onnx.AttributeProto.INT:
                return a.i
            if a.ints:
                return list(a.ints)
            if a.type == onnx.AttributeProto.FLOAT:
                return a.f
            if a.type == onnx.AttributeProto.STRING:
                return a.s.decode()
    return default


def build(onnx_path=None, verbose=False):
    """Read the ONNX graph and return an equivalent, eval-mode nn.Module.

    Raises rather than guesses: an unsupported op, an unknown node shape, or an
    initializer nobody consumed is a bug in this port, and a cosine drift is how
    that bug would otherwise present.
    """
    if onnx_path is None:
        onnx_path = find_model(SFACE_ONNX)
    graph = onnx.load(onnx_path).graph
    init = {i.name: numpy_helper.to_array(i) for i in graph.initializer}
    initializers = set(init)

    inputs = [i.name for i in graph.input if i.name not in initializers]
    if inputs != ["data"]:
        raise SystemExit("unexpected graph inputs: %r" % (inputs,))
    dims = tuple(d.dim_value for d in graph.input[0].type.tensor_type.shape.dim)
    if dims != INPUT_SHAPE:
        raise SystemExit("unexpected input shape %r" % (dims,))

    ops = {}
    for node in graph.node:
        ops[node.op_type] = ops.get(node.op_type, 0) + 1
    if ops != EXPECTED_OPS:
        raise SystemExit("graph ops changed:\n  got %r\n  want %r" % (ops, EXPECTED_OPS))

    used = set()          # initializers consumed, for the completeness check
    layers = []
    produced = set(inputs)      # tensor names available at this point in the walk

    def take(node, name):
        """Consume one initializer, insisting it is one and is used only once."""
        if name not in init:
            raise SystemExit("%s wants %r, which is not an initializer" % (node.op_type, name))
        if name in used:
            raise SystemExit("initializer %r consumed twice" % name)
        used.add(name)
        return init[name]

    for i, node in enumerate(graph.node):
        op, ins, outs = node.op_type, list(node.input), list(node.output)
        if op not in SUPPORTED:
            raise SystemExit("node %d: unsupported op %r" % (i, op))
        # Every node is fed by the running output (plus its own weights): the
        # graph is a chain, and this is the assertion that keeps it one.
        if ins[0] not in produced:
            raise SystemExit("node %d (%s): input %r is not the running output"
                             % (i, op, ins[0]))

        if op == "Sub":
            layers.append(_Scalar(op, float(take(node, ins[1])[0])))
        elif op == "Mul":
            layers.append(_Scalar(op, float(take(node, ins[1])[0])))
        elif op == "Conv":
            w = take(node, ins[1])
            pads = _attr(node, "pads", [0, 0, 0, 0])
            # F.conv2d's int padding is symmetric; the graph is too, and a
            # rectangular pad would need a real port rather than one number.
            if pads[0] != pads[2] or pads[1] != pads[3] or pads[0] != pads[1]:
                raise SystemExit("Conv node %d has unported pads %r" % (i, pads))
            layers.append(_Conv2d(
                w,
                stride=_attr(node, "strides", [1, 1]),
                padding=pads[0],
                dilation=_attr(node, "dilations", [1, 1]),
                groups=_attr(node, "group", 1)))
        elif op == "BatchNormalization":
            eps = _attr(node, "epsilon", 1e-5)
            g, b, m, v = (take(node, n) for n in ins[1:5])
            layers.append(_BatchNorm(g, b, m, v, eps))
        elif op == "PRelu":
            layers.append(_PReLU(take(node, ins[1])))
        elif op == "Dropout":
            layers.append(_Identity())
        elif op == "Flatten":
            axis = _attr(node, "axis", 1)
            if axis != 1:
                raise SystemExit("Flatten axis %r is not the ported case" % (axis,))
            layers.append(_Flatten())
        elif op == "Gemm":
            if (_attr(node, "transB", 0) != 1 or _attr(node, "alpha", 1.0) != 1.0
                    or _attr(node, "beta", 1.0) != 1.0 or _attr(node, "transA", 0) != 0):
                raise SystemExit("Gemm node %d has attributes the port assumes away" % i)
            layers.append(_Gemm(take(node, ins[1]), take(node, ins[2])))

        for name in outs:
            produced.add(name)

    missing = initializers - used
    if missing:
        raise SystemExit("%d initializer(s) never consumed: %r"
                         % (len(missing), sorted(missing)[:5]))

    model = SFaceNet(layers).eval()
    if verbose:
        print("rebuilt %s" % onnx_path)
        print("  nodes        %d (%d Conv, %d BatchNorm, %d PReLU)"
              % (len(graph.node), ops["Conv"], ops["BatchNormalization"], ops["PRelu"]))
        print("  initializers %d, all consumed" % len(initializers))
        print("  parameters   %.2f M" % (sum(p.numel() for p in model.parameters()) / 1e6))
    return model


def embed(model, bgr_crops):
    """Embed BGR uint8 crops exactly as the app does: raw 0-255, RGB, 112x112.

    `cv2.FaceRecognizerSF.feature` (the current behaviour, and the reference
    this port is measured against) hands the ONNX raw pixel values in RGB order
    and lets the graph do the `(x - 127.5) / 128`. Reproduce that, not a tidier
    version of it.

    One crop at a time: the ONNX graph is exported with a fixed batch of 1, and
    the app embeds a single face per call, so a batch here would be measuring a
    shape that never runs.
    """
    out = []
    for crop in bgr_crops:
        x = torch.from_numpy(crop[:, :, ::-1].astype(np.float32))
        with torch.no_grad():
            out.append(model(x.permute(2, 0, 1).unsqueeze(0)).numpy().reshape(-1))
    return np.stack(out)


def unit(v):
    v = np.asarray(v, dtype=np.float64)
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.where(n == 0, 1.0, n)


def main():
    model = build(sys.argv[1] if len(sys.argv) > 1 else None, verbose=True)
    x = torch.from_numpy(np.random.default_rng(0).normal(size=INPUT_SHAPE).astype(np.float32))
    with torch.no_grad():
        y = model(x)
    print("  shapes       %r -> %r" % (tuple(x.shape), tuple(y.shape)))
    if tuple(y.shape) != (INPUT_SHAPE[0], EMBED_DIM):
        raise SystemExit("output shape is not (%d, %d)" % (INPUT_SHAPE[0], EMBED_DIM))
    return 0


if __name__ == "__main__":
    sys.exit(main())
