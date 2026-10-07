"""Overall verdict, exit codes and the printed summary."""


EXIT_CODES = {"PASS": 0, "FAIL": 1, "INCONCLUSIVE": 2, "BLOCKED": 3, "GUARD_STOP": 4}


def overall(verdicts, guard=None):
    if guard is not None and not guard.blocked:
        return "GUARD_STOP"
    values = {item["verdict"] for item in verdicts}
    for value in ("FAIL", "BLOCKED", "INCONCLUSIVE"):
        if value in values:
            return value
    if guard is not None:
        return "BLOCKED"
    return "PASS" if values else "INCONCLUSIVE"


SSL_HINT = ("Python could not verify HTTPS certificates; with the python.org build on macOS set "
            "SSL_CERT_FILE=/etc/ssl/cert.pem or run Install Certificates.command")


def hints(summary):
    texts = list(summary["readiness"]["reasons"]) + [item["reason"] for item in summary["verdicts"]]
    return [SSL_HINT] if any("CERTIFICATE_VERIFY_FAILED" in text for text in texts) else []


def render(summary):
    lines = ["run      %s" % summary["run_id"],
             "target   %s (%s)" % (summary["target"], summary["preset"])]
    facts = summary["readiness"].get("facts") or {}
    if facts:
        lines.append("chain    height %d, epoch %d, offset %d of %d, send window %d..%d" % (
            facts["height"], facts["epoch"], facts["epoch_offset"], facts["epoch_length"],
            facts["send_window"][0], facts["send_window"][1]))
    readiness = summary["readiness"]
    if readiness["state"] != "SKIPPED":
        lines.append("ready    %s" % readiness["state"])
    for reason in readiness["reasons"]:
        lines.append("         %s" % reason)
    for item in summary["verdicts"]:
        lines.append("%-12s %-14s %-15s %s" % (
            item["verdict"], item["check"], ",".join(item["maps"]), item["reason"]))
    if summary.get("guard"):
        guard = summary["guard"]
        lines.append("guard    %s: %s" % (guard["reason"], guard["advice"]))
    for hint in summary.get("hints", []):
        lines.append("hint     %s" % hint)
    lines.append("posts    %d" % summary["posts"])
    lines.append("overall  %s (exit %d)" % (summary["overall"], summary["exit_code"]))
    lines.append("records  %s" % summary["run_dir"])
    return "\n".join(lines)
