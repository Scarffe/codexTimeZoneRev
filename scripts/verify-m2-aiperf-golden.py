#!/usr/bin/env python3
"""Offline original-source metric oracle, not an AIPerf installation/runtime.

Only selected original AST function bodies are executed, after blob-hash checks.
Thin stubs supply records, dependency values, response types and ns->s conversion.
No imports from the upstream package, networking or third-party Python dependencies.
"""
from __future__ import annotations

import argparse
import ast
import copy
import hashlib
import json
import math
from pathlib import Path
from types import SimpleNamespace as NS

ROOT = Path(__file__).resolve().parents[1]
COMMIT = "b1746a84a4665810abebb5ab09a6677d371c9e22"
METRIC_DIR = "src/aiperf/metrics/types/"
HASHES = {
    "LICENSE": "f3fe76ecadf88e6fa1f23005a590a7f0f3500cfe",
    METRIC_DIR + "inter_token_latency_metric.py": "0a7a78c9e333442e0d96d1375bf5cc43c120ed31",
    METRIC_DIR + "output_token_throughput_metrics.py": "231f41e70a441d313b94ee6e56e680349508e74f",
    METRIC_DIR + "time_to_first_output_token_metric.py": "b59e9ac356d7162051b3c218000fe5ffb4812e79",
    METRIC_DIR + "ttft_metric.py": "6283af379f47d9e94d5f5fcfc29e326750e8a99b",
    METRIC_DIR + "e2e_output_throughput_metric.py": "557522226eefce6fb85f8cc5fbd5b22eda2a10e7",
    METRIC_DIR + "request_latency_metric.py": "a2f2923d8dda7573dcbfaeea45a82d90e94773a9",
    METRIC_DIR + "decode_duration_metric.py": "119fc579a9c4be2f1eace0e447dcdbcead6c532c",
    METRIC_DIR + "output_sequence_length_metric.py": "1c69940b8c31a15220dd20a0f179acbbc2399990",
    "tests/unit/metrics/test_inter_token_latency_metric.py": "06f0b3f7df152c9040e44d219d01d398ba3c58cc",
}


class NoMetricValue(Exception):
    pass


class TextResponseData:
    def __init__(self, text=""):
        self.text = text


class ReasoningResponseData:
    def __init__(self, content="", reasoning="synthetic"):
        self.content, self.reasoning = content, reasoning


class ToolCallResponseData:
    def __init__(self, tool_call_text="synthetic"):
        self.tool_call_text = tool_call_text


def blob_hash(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def check_close(actual, expected, label):
    if expected is None:
        assert actual is None, f"{label}: expected unavailable, got {actual}"
    else:
        assert actual is not None and math.isfinite(actual), f"{label}: missing/nonfinite"
        assert math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-12), (
            f"{label}: {actual} != {expected}"
        )


class Values:
    def __init__(self):
        self.values = {}

    def get_or_raise(self, metric):
        if metric.__name__ not in self.values:
            raise NoMetricValue("missing dependency")
        return self.values[metric.__name__]

    def get_converted_or_raise(self, metric, time_unit):
        assert time_unit == "seconds"
        return self.get_or_raise(metric) / 1_000_000_000


SPECS = [
    ("OutputSequenceLengthMetric", "output_sequence_length_metric.py", "osl", "tokens"),
    ("TTFTMetric", "ttft_metric.py", "ttftNs", "ns"),
    ("RequestLatencyMetric", "request_latency_metric.py", "requestLatencyNs", "ns"),
    ("DecodeDurationMetric", "decode_duration_metric.py", "decodeNs", "ns"),
    ("InterTokenLatencyMetric", "inter_token_latency_metric.py", "itlNs", "ns"),
    ("OutputTokenThroughputPerUserMetric", "output_token_throughput_metrics.py", "streamTokensPerSecond", "tokens/s"),
    ("FullDecodeDurationMetric", "decode_duration_metric.py", "fullDecodeNs", "ns"),
    ("FullResponseInterTokenLatencyMetric", "inter_token_latency_metric.py", "fullItlNs", "ns"),
    ("FullResponseOutputTokenThroughputPerUserMetric", "output_token_throughput_metrics.py", "fullTokensPerSecond", "tokens/s"),
    ("E2EOutputTokenThroughputMetric", "e2e_output_throughput_metric.py", "e2eTokensPerSecond", "tokens/s"),
    ("TimeToFirstOutputTokenMetric", "time_to_first_output_token_metric.py", "ttfoNs", "ns"),
]


class Oracle:
    def __init__(self, reference):
        # Every selected input (including original tests/license) is verified before any exec.
        self.bytes = {}
        for relative, expected in HASHES.items():
            data = (reference / relative).read_bytes()
            actual = blob_hash(data)
            assert actual == expected, f"source hash mismatch: {relative}"
            self.bytes[relative] = data
        self.trees = {p: ast.parse(b.decode("utf-8"), filename=p)
                      for p, b in self.bytes.items() if p.endswith(".py")}
        self.executed = []
        self.warnings = []
        self.ns = {
            "NoMetricValue": NoMetricValue,
            "TextResponseData": TextResponseData,
            "ReasoningResponseData": ReasoningResponseData,
            "ToolCallResponseData": ToolCallResponseData,
            "_mismatch_warnings": NS(warn_once=lambda *args: self.warnings.append(args)),
        }
        for name, _, _, _ in SPECS:
            self.ns[name] = type(name, (), {"tag": name, "unit": NS(time_unit="seconds")})
        self.load(METRIC_DIR + "inter_token_latency_metric.py", None, "_decode_token_count")
        self.methods = {}
        for name, path, _, _ in SPECS:
            self.methods[name] = self.load(METRIC_DIR + path, name, "_parse_record")

    def load(self, path, owner, method):
        nodes = self.trees[path].body
        if owner:
            nodes = next(n for n in nodes if isinstance(n, ast.ClassDef) and n.name == owner).body
        original = next(n for n in nodes if isinstance(n, ast.FunctionDef) and n.name == method)
        assert not original.decorator_list
        function = copy.deepcopy(original)
        function.name = (owner + "__" if owner else "") + method
        # Body and annotations are original; only the binding name changes outside the body.
        module = ast.Module(body=[function], type_ignores=[])
        exec(compile(module, path, "exec"), self.ns)
        self.executed.append(f"{path}:{owner + '.' if owner else ''}{method}")
        return self.ns[function.name]

    def pipeline(self, record):
        values = Values()
        result = {}
        for name, _, key, unit in SPECS:
            try:
                value = self.methods[name](self.ns[name](), record, values)
                values.values[name] = value
                result[key] = {"value": value, "unit": unit, "valid": True}
            except (NoMetricValue, ValueError, ZeroDivisionError) as error:
                result[key] = {"value": None, "unit": unit, "valid": False,
                               "unavailableKind": type(error).__name__}
        return result

    def original_controls(self):
        # Execute these two actual saved upstream test bodies, including original assertions.
        class Approx:
            def __init__(self, want):
                self.want = want

            def __eq__(self, actual):
                if isinstance(self.want, list):
                    return len(actual) == len(self.want) and all(
                        math.isclose(a, b, rel_tol=1e-12) for a, b in zip(actual, self.want)
                    )
                return math.isclose(actual, self.want, rel_tol=1e-12)

        created = []

        def create_record(start_ns=100, responses=None, output_tokens_per_response=1,
                          first_content_chunk_tokens=None):
            rows = responses or [start_ns + 50]
            case = {"startNs": start_ns, "content": [[ns, "text"] for ns in rows],
                    "endNs": rows[-1], "outputTokens": len(rows) * output_tokens_per_response,
                    "reasoningTokens": None, "firstChunkTokens": first_content_chunk_tokens}
            created.append(case)
            return make_record(case)

        def run_simple_metrics_pipeline(records, *tags):
            rows = [self.pipeline(record) for record in records]
            return {name: [row[key]["value"] for row in rows if row[key]["valid"]]
                    for name, _, key, _ in SPECS if name in tags}

        self.ns.update(create_record=create_record, run_simple_metrics_pipeline=run_simple_metrics_pipeline,
                       approx=Approx)
        controls = []
        for name in ["test_inter_token_latency_subtracts_bundled_first_chunk",
                     "test_inter_token_latency_absent_first_chunk_falls_back_to_one"]:
            function = self.load("tests/unit/metrics/test_inter_token_latency_metric.py",
                                 "TestInterTokenLatencyMetric", name)
            function(NS())
            case = created[-1]
            assert case["startNs"] == 100 and case["outputTokens"] == 6
            controls.append({"originalTest": name, "input": case,
                             "result": self.pipeline(make_record(case)), "passed": True})
        return controls


def make_record(case):
    responses = []
    for ns, kind in case["content"]:
        data = {"text": lambda: TextResponseData("synthetic"),
                "reasoning": ReasoningResponseData, "tool": ToolCallResponseData}[kind]()
        responses.append(NS(perf_ns=ns, data=data))
    reasoning = case["reasoningTokens"]
    # Upstream internal output is non-reasoning; raw API completion count is inclusive.
    output = case["outputTokens"] - (reasoning or 0)
    return NS(start_perf_ns=case["startNs"],
              request=NS(start_perf_ns=case["startNs"], end_perf_ns=case["endNs"]),
              content_responses=responses,
              token_counts=NS(output=output, reasoning=reasoning,
                              first_content_chunk_tokens=case["firstChunkTokens"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, default=ROOT / "environment/stage-m2-reference/aiperf")
    parser.add_argument("--golden", type=Path, default=ROOT / "native/launcher_core/tests/fixtures/benchmark/aiperf-m2-golden.json")
    parser.add_argument("--receipt", type=Path, default=ROOT / "environment/stage-m2-aiperf-oracle.json")
    args = parser.parse_args()
    golden = json.loads(args.golden.read_text(encoding="utf-8-sig"))
    assert golden["sourceCommit"] == COMMIT
    oracle = Oracle(args.reference_root)
    controls = oracle.original_controls()
    outputs = []
    for case in golden["cases"]:
        result = oracle.pipeline(make_record(case))
        for key, expected in case["upstream"].items():
            check_close(result[key]["value"], expected, case["id"] + ":" + key)
            assert result[key]["valid"] == (expected is not None)
        assert result["osl"]["value"] == case["outputTokens"], "reasoning subset added twice"
        # Compare common project mappings, and prove the two deliberate boundary adaptations.
        for upstream, project in [("ttftNs", "ttftMs"), ("ttfoNs", "ttfoMs")]:
            if project == "ttfoMs" and any(kind == "tool" for _, kind in case["content"]):
                assert case["project"][project] is None and result[upstream]["valid"]
                continue
            actual = result[upstream]["value"]
            check_close(None if actual is None else actual / 1_000_000,
                        case["project"][project], case["id"] + ":project:" + project)
        for upstream, project in [("streamTokensPerSecond", "streamTokensPerSecond"),
                                  ("fullTokensPerSecond", "fullResponseTokensPerSecond")]:
            if case["project"][project] is not None:
                check_close(result[upstream]["value"], case["project"][project], case["id"] + ":project:" + project)
        # This is an explicit project denominator adaptation, not an upstream formula rewrite.
        expected_http_e2e = case["outputTokens"] * 1_000_000_000 / (case["endNs"] - case["startNs"])
        check_close(expected_http_e2e, case["project"]["e2eTokensPerSecond"], case["id"] + ":HTTP_EOF_adaptation")
        outputs.append({"id": case["id"], "input": {k: v for k, v in case.items() if k not in ("upstream", "project")},
                        "upstream": result, "projectExpected": case["project"], "passed": True})
    assert (ROOT / "licenses/AIPerf-Apache-2.0.txt").read_bytes() == oracle.bytes["LICENSE"]
    receipt = {"sourceCommit": COMMIT, "execution": "hash-verified-original-AST-functions-with-minimal-stubs",
               "fullAIPerfInstalledOrExecuted": False, "sourceBlobSha1": HASHES,
               "stubs": ["SimpleNamespace request/record/token counts", "three response data classes",
                         "NoMetricValue", "metric dependency dictionary", "ns-to-seconds conversion",
                         "warn-once sink", "original test create_record/pipeline/approx"],
               "executedBodies": oracle.executed, "originalControls": controls,
               "adaptations": golden["adaptations"], "cases": outputs, "passed": True}
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: {len(HASHES)} hashes, {len(controls)} original upstream test bodies, "
          f"{len(outputs)} golden cases; receipt={args.receipt}")


if __name__ == "__main__":
    main()
