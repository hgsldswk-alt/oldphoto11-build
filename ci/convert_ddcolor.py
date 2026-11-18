import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
import urllib.request
from importlib.metadata import version
from pathlib import Path


SOURCE = "https://github.com/piddnad/DDColor.git"
SOURCE_REV = "2adb63f2656ac41cbdf7b894cddd94121a3faf13"
MODEL = "https://huggingface.co/piddnad/ddcolor_paper_tiny"
MODEL_REV = "cf9fd99c1d7472689ec7413441c1b799a51866a3"
WEIGHT_SHA = "8a1277bc90a1bfbb6d2d83933a9a6bc821931879ca93e26e4fcec12165d41fce"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(url, target):
    with urllib.request.urlopen(url, timeout=120) as source, target.open("wb") as destination:
        shutil.copyfileobj(source, destination)


def model_inputs(edge):
    import numpy as np

    grid = np.linspace(0.08, 0.92, edge, dtype=np.float32)
    bands = (np.sin(grid[:, None] * 14) * np.cos(grid[None, :] * 18) + 1) * 0.38 + 0.12
    return [np.tile(sample[None, None], (1, 3, 1, 1)).astype(np.float32)
            for sample in [np.tile(grid, (edge, 1)), bands]]


def convert(model, edge, target, identifier, allow_quantization):
    import coremltools as ct
    import numpy as np
    import torch

    inputs = model_inputs(edge)
    with torch.no_grad():
        reference = [model(torch.from_numpy(sample)).numpy() for sample in inputs]
        traced = torch.jit.trace(model, torch.from_numpy(inputs[0]), check_trace=False)
        for sample, expected in zip(inputs, reference, strict=True):
            np.testing.assert_allclose(traced(torch.from_numpy(sample)).numpy(), expected, atol=0.02, rtol=0.002)
    precision = ct.precision.FLOAT16
    converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                           compute_precision=precision, compute_units=ct.ComputeUnit.CPU_ONLY,
                           inputs=[ct.TensorType(name="gray_rgb", shape=(1, 3, edge, edge), dtype=np.float32)],
                           outputs=[ct.TensorType(name="lab_ab", dtype=np.float32)])

    def validate(candidate, mean_limit, p99_limit):
        metrics = []
        for sample, expected in zip(inputs, reference, strict=True):
            output = candidate.predict({"gray_rgb": sample})["lab_ab"]
            if output.shape != (1, 2, edge, edge) or output.dtype != np.float32 or not np.isfinite(output).all():
                raise ValueError("Invalid CPU output")
            delta = np.abs(output - expected)
            mae, p99 = float(delta.mean()), float(np.percentile(delta, 99))
            if mae > mean_limit or p99 > p99_limit:
                raise ValueError(f"Lab chroma error is too large: MAE={mae:.3f}, P99={p99:.3f}")
            metrics.append({"mae": mae, "p99": p99})
        return metrics

    report = {"fp16": validate(converted, 2, 7), "selected": "fp16"}
    if allow_quantization:
        try:
            from coremltools.optimize.coreml import OptimizationConfig, OpLinearQuantizerConfig, linear_quantize_weights

            int8 = OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", weight_threshold=2048)
            config = OptimizationConfig(op_type_configs={"conv": int8, "linear": int8})
            candidate = linear_quantize_weights(converted, config=config)
            report["mixed-int8"] = validate(candidate, 3, 10)
            def package_size(model):
                with tempfile.TemporaryDirectory(prefix="ddcolor-size-") as scratch:
                    package = Path(scratch) / "test.mlpackage"
                    model.save(str(package))
                    return sum(path.stat().st_size for path in package.rglob("*") if path.is_file())

            report["candidate_package_bytes"] = package_size(candidate)
            report["fp16_package_bytes"] = package_size(converted)
            if report["candidate_package_bytes"] < report["fp16_package_bytes"]:
                converted = candidate
                report["selected"] = "mixed-int8"
        except Exception as reason:
            report["mixed-int8-rejected"] = str(reason)
    converted.version = f"{identifier}-{report['selected']}"
    converted.short_description = "Local Lab chroma only; gray_rgb and lab_ab are NCHW float32."
    if allow_quantization:
        converted.author = "DDColor authors; converted for OldPhoto"
        converted.license = "Apache-2.0"
    converted.save(str(target))
    report["files_sha256"] = {str(path.relative_to(target)): digest(path) for path in sorted(target.rglob("*")) if path.is_file()}
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", action="store_true")
    args = parser.parse_args()

    import torch

    torch.set_num_threads(2)
    torch.backends.mha.set_fastpath_enabled(False)
    torch.manual_seed(20261118)
    args.output.mkdir(parents=True, exist_ok=True)
    if args.fixture:
        class Fixture(torch.nn.Module):
            def forward(self, gray):
                return torch.cat((gray[:, :1] * 12 + 18, gray[:, :1] * 9 + 10), dim=1)

        details = convert(Fixture().eval(), 16, args.output / "DDColorFixture.mlpackage", "fixture", False)
        (args.output / "fixture-report.json").write_text(json.dumps(details, indent=2) + "\n", encoding="utf-8")
        return
    with tempfile.TemporaryDirectory(prefix="ddcolor-") as folder:
        import sys

        root = Path(folder)
        upstream = root / "source"
        subprocess.run(["git", "init", str(upstream)], check=True)
        subprocess.run(["git", "-C", str(upstream), "fetch", "--depth=1", SOURCE, SOURCE_REV], check=True)
        subprocess.run(["git", "-C", str(upstream), "checkout", "--detach", "FETCH_HEAD"], check=True)
        actual = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
        if actual != SOURCE_REV:
            raise RuntimeError("DDColor source revision mismatch")
        weights = root / "pytorch_model.bin"
        download(f"{MODEL}/resolve/{MODEL_REV}/pytorch_model.bin", weights)
        if digest(weights) != WEIGHT_SHA:
            raise RuntimeError("DDColor checkpoint SHA-256 mismatch")
        config = root / "config.json"
        download(f"{MODEL}/resolve/{MODEL_REV}/config.json", config)
        sys.path.insert(0, str(upstream))
        from ddcolor import DDColor

        model = DDColor(**json.loads(config.read_text(encoding="utf-8"))).eval()
        checkpoint = torch.load(weights, map_location="cpu", weights_only=True)
        state = checkpoint.get("params", checkpoint) if isinstance(checkpoint, dict) else checkpoint
        model.load_state_dict(state, strict=True)
        for module in model.modules():
            if hasattr(module, "weight_u") and hasattr(module, "weight_orig"):
                torch.nn.utils.remove_spectral_norm(module)
            elif hasattr(module, "weight_g") and hasattr(module, "weight_v"):
                torch.nn.utils.remove_weight_norm(module)
        report = convert(model, 512, args.output / "DDColor.mlpackage", "ddcolor-paper-tiny-lab-v1", True)
        report.update(source_revision=SOURCE_REV, weight_revision=MODEL_REV, weight_sha256=WEIGHT_SHA,
                      config_sha256=digest(config), dependencies={package: version(package) for package in
                          ("torch", "torchvision", "coremltools", "numpy", "opencv-python")})
        shutil.copyfile(upstream / "LICENSE", args.output / "LICENSE.txt")
        notice = upstream / "NOTICE"
        original_notice = notice.read_text(encoding="utf-8") + "\n\n" if notice.is_file() else ""
        (args.output / "NOTICE.txt").write_text(
            original_notice + f"DDColor Paper Tiny by the DDColor authors. Apache-2.0.\n"
            f"Source: {SOURCE} @ {SOURCE_REV}\nWeights: {MODEL} @ {MODEL_REV}\nSHA-256: {WEIGHT_SHA}\n"
            "Changed by OldPhoto: frozen normalization, Core ML conversion and weight compression where validated.\n"
            "Paper: https://arxiv.org/abs/2212.11613\n"
            "Training provenance: see the original paper and model card; no training images bundled.\n",
            encoding="utf-8")
        (args.output / "conversion-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
