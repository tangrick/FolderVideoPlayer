#!/usr/bin/env python3
"""Task 6.2 — YuNet as a PyTorch module, rebuilt from the ONNX graph.

YuNet is the *detector*: it finds faces and, more importantly, produces the five
landmarks the face crop is aligned from. Phase 6.1 ported SFace (identity) and
this is its other half. Its graph is 106 nodes of ordinary ops — Conv, Relu,
MaxPool, Resize (a 2x nearest upsample), Add (two residuals), Transpose,
Reshape, Sigmoid — ending in the raw per-anchor tensors, so the decode and NMS
are ours to write (`yunet_parity.py` is the specification, measured against
`cv2.FaceDetectorYN` to 0.0001 px).

Three properties of this graph the port depends on, all verified here:

  - **Every `Reshape` targets `[1, -1, k]`.** The network is fully convolutional,
    which is why OpenCV can run it at any multiple of 32 and why the Core ML
    model can take a dynamic height and width. A fixed 640x640 input was the
    first wrong guess in 6.2 and it cost a mean 178 px of box error.
  - **All 53 Convs carry a bias**, and 20 of them are depthwise (`group>1`).
  - **Two `Add` nodes take two data inputs** — unlike SFace, this graph is not a
    chain, so the interpreter carries a value table keyed by tensor name rather
    than a single running value.

Like `sface_torch.py`, the module is generated from the graph and asserts that
every initializer is consumed exactly once: a dropped weight would show up as a
slightly wrong box, which reads like numerical noise rather than a bug.

    /opt/anaconda3/bin/python3 docs/coreml-spike/yunet_torch.py
"""

import os
import sys

import numpy as np
import onnx
import torch
import torch.nn as nn
import torch.nn.functional as F
from onnx import numpy_helper

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sface_torch                                     # noqa: E402

SUPPORTED = {"Conv", "Relu", "MaxPool", "Resize", "Add", "Transpose",
             "Reshape", "Sigmoid"}
EXPECTED_OPS = {"Conv": 53, "Relu": 15, "MaxPool": 4, "Resize": 2, "Add": 2,
                "Transpose": 12, "Reshape": 12, "Sigmoid": 6}
# The order the ONNX declares them, so a caller can address outputs by name.
OUTPUT_NAMES = ["cls_8", "cls_16", "cls_32", "obj_8", "obj_16", "obj_32",
                "bbox_8", "bbox_16", "bbox_32", "kps_8", "kps_16", "kps_32"]
DIVISOR = 32


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


class YunetNet(nn.Module):
    """The rebuilt network. Carries a value table, because the graph branches."""

    def __init__(self, plan, constants):
        super().__init__()
        self.plan = plan
        self.output_names = list(OUTPUT_NAMES)
        for name, value in constants.items():
            self.register_buffer(name, torch.from_numpy(value.astype(np.float32)))

    def forward(self, x):
        v = {"input": x}
        for step in self.plan:
            op = step[0]
            if op == "conv":
                _, out, src, weight, bias, stride, pad, dil, group = step
                v[out] = F.conv2d(v[src], getattr(self, weight), getattr(self, bias),
                                  stride, pad, dil, group)
            elif op == "relu":
                v[step[1]] = F.relu(v[step[2]])
            elif op == "maxpool":
                _, out, src, kernel, stride = step
                v[out] = F.max_pool2d(v[src], kernel, stride)
            elif op == "resize":
                _, out, src, scale = step
                v[out] = F.interpolate(v[src], scale_factor=scale, mode="nearest")
            elif op == "add":
                v[step[1]] = v[step[2]] + v[step[3]]
            elif op == "transpose":
                v[step[1]] = v[step[2]].permute(*step[3])
            elif op == "reshape":
                v[step[1]] = v[step[2]].reshape(step[3])
            elif op == "sigmoid":
                v[step[1]] = torch.sigmoid(v[step[2]])
            else:
                raise AssertionError("unhandled op %r" % op)
        return tuple(v[name] for name in self.output_names)


def _safe(name):
    """A buffer name torch will accept — initializer names include bare digits."""
    return "c_" + "".join(ch if ch.isalnum() else "_" for ch in name)


def build(onnx_path=None, verbose=False):
    """Read the ONNX graph and return an equivalent, eval-mode nn.Module."""
    if onnx_path is None:
        onnx_path = sface_torch.find_model(sface_torch.YUNET_ONNX)
    graph = onnx.load(onnx_path).graph
    init = {i.name: numpy_helper.to_array(i) for i in graph.initializer}
    declared = set(init)

    ops = {}
    for node in graph.node:
        ops[node.op_type] = ops.get(node.op_type, 0) + 1
    if ops != EXPECTED_OPS:
        raise SystemExit("graph ops changed:\n  got %r\n  want %r" % (ops, EXPECTED_OPS))

    inputs = [i.name for i in graph.input if i.name not in declared]
    if inputs != ["input"]:
        raise SystemExit("unexpected graph inputs: %r" % (inputs,))

    constants = {_safe(name): value for name, value in init.items()}
    used = set()
    plan = []
    value_names = set(inputs)
    constants_only = set()

    def take(name, what):
        if name not in init:
            raise SystemExit("%s wants %r, which is not an initializer" % (what, name))
        used.add(name)
        return _safe(name)

    for i, node in enumerate(graph.node):
        op, ins, outs = node.op_type, list(node.input), list(node.output)
        if op not in SUPPORTED:
            raise SystemExit("node %d: unsupported op %r" % (i, op))

        if op == "Conv":
            if len(ins) != 3:
                raise SystemExit("Conv node %d has no bias — the port assumes one" % i)
            pads = _attr(node, "pads", [0, 0, 0, 0])
            if pads[0] != pads[2] or pads[1] != pads[3] or pads[0] != pads[1]:
                raise SystemExit("Conv node %d has unported pads %r" % (i, pads))
            plan.append(("conv", outs[0], ins[0], take(ins[1], "Conv"), take(ins[2], "Conv"),
                         _attr(node, "strides", [1, 1]), pads[0],
                         _attr(node, "dilations", [1, 1]), _attr(node, "group", 1)))
        elif op == "Relu":
            plan.append(("relu", outs[0], ins[0]))
        elif op == "MaxPool":
            kernel = _attr(node, "kernel_shape", [2, 2])
            pads = _attr(node, "pads", [0, 0, 0, 0])
            if any(pads) or _attr(node, "ceil_mode", 0):
                raise SystemExit("MaxPool node %d has unported pads/ceil_mode" % i)
            plan.append(("maxpool", outs[0], ins[0], kernel, _attr(node, "strides", kernel)))
        elif op == "Resize":
            if _attr(node, "mode") != "nearest" or _attr(node, "coordinate_transformation_mode") != "asymmetric":
                raise SystemExit("Resize node %d is not the ported case" % i)
            take(ins[1], "Resize roi")                      # consumed and unused
            scales = init[ins[2]].astype(int).tolist()
            if scales[0] != 1 or scales[1] != 1 or len(set(scales[2:])) != 1:
                raise SystemExit("Resize node %d has unported scales %r" % (i, scales))
            used.add(ins[2])
            plan.append(("resize", outs[0], ins[0], int(scales[2])))
        elif op == "Add":
            plan.append(("add", outs[0], ins[0], ins[1]))
        elif op == "Transpose":
            plan.append(("transpose", outs[0], ins[0], _attr(node, "perm")))
        elif op == "Reshape":
            shape = init[ins[1]].astype(int).tolist()
            if shape[1] != -1:
                raise SystemExit("Reshape node %d does not infer its middle dim: %r"
                                 % (i, shape))
            used.add(ins[1])
            plan.append(("reshape", outs[0], ins[0], shape))
        elif op == "Sigmoid":
            plan.append(("sigmoid", outs[0], ins[0]))

        for name in outs:
            value_names.add(name)

    # Only tensors of size zero are legitimately unused (the Resize `roi`).
    unused = [n for n in declared - used if init[n].size > 0]
    if unused:
        raise SystemExit("%d initializer(s) never consumed: %r" % (len(unused), sorted(unused)[:5]))
    for name in OUTPUT_NAMES:
        if name not in value_names:
            raise SystemExit("declared output %r is never produced" % name)
    constants_only.update(constants)

    model = YunetNet(plan, constants).eval()
    if verbose:
        print("rebuilt %s" % onnx_path)
        print("  nodes        %d, all supported" % len(graph.node))
        print("  initializers %d, all consumed" % len(init))
        print("  parameters   %.3f M" % (sum(p.numel() for p in model.parameters()) / 1e6))
        print("  buffers      %.3f M" % (sum(b.numel() for b in model.buffers()) / 1e6))
        print("  outputs      %d" % len(OUTPUT_NAMES))
    return model


def main():
    model = build(verbose=True)
    # A snapshot resolution that is a multiple of 32, as the frames always are.
    x = torch.zeros(1, 3, 1024, 576)
    with torch.no_grad():
        out = model(x)
    print("  shapes       %r -> %d tensors" % (tuple(x.shape), len(out)))
    for name, tensor in zip(OUTPUT_NAMES, out):
        print("     %-8s %r" % (name, tuple(tensor.shape)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
