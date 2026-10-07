"""Stop rules applied after every completion POST; a POST is never retried."""


# The proxy and the chain disagree on the runtime protocol: waiting will not help.
CONFIG_REJECTIONS = {
    "admission_protocol_not_configured",
    "admission_protocol_not_approved",
    "admission_protocol_approval_invalid",
}


class GuardStop(Exception):
    def __init__(self, reason, advice, seq, blocked=False):
        super().__init__(reason)
        self.reason = reason
        self.advice = advice
        self.seq = seq
        self.blocked = blocked

    def to_dict(self):
        return {"reason": self.reason, "advice": self.advice, "record": self.seq,
                "blocked": self.blocked}


class Guards:
    def __init__(self, admission=True):
        self.admission = admission
        self.rejections = []

    def after_post(self, reply):
        gdc = reply.gdc
        code = reply.error_code or ""
        if reply.transport_error:
            raise GuardStop("unknown_outcome", "the request may have been dispatched; "
                            "check the admission proxy before sending again", reply.seq)
        # The proxy's first deadline check in dispatch_once keeps the permit:
        # every later completion waits until the proxy restarts.
        if (reply.status == 408 and code == "admission_deadline_elapsed"
                and "permit_height" in gdc and "dispatch_height" not in gdc):
            raise GuardStop("permit_leak_suspected", "check the admission proxy; "
                            "a restart is the operator's decision", reply.seq)
        if not self.admission:
            if reply.status is not None and reply.status >= 500 and code.startswith("gateway_dispatch_"):
                raise GuardStop("gateway_dispatch_failure", "the gateway could not complete the request", reply.seq)
            return
        if "admission" not in gdc:
            raise GuardStop("no_admission_header", "the reply did not come from the admission proxy",
                            reply.seq)
        if gdc["admission"] == "dispatch_attempt_failed" or (
                reply.status >= 500 and code.startswith("gateway_dispatch_")):
            raise GuardStop("gateway_dispatch_failure", "the proxy could not complete its one dispatch",
                            reply.seq)
        if gdc["admission"] == "pre_dispatch_rejected" and code in CONFIG_REJECTIONS:
            raise GuardStop("proxy_misconfigured", "the admission proxy rejected the runtime protocol (%s); "
                            "check its protocol contracts against the chain" % code, reply.seq)
        if gdc["admission"] == "pre_dispatch_rejected":
            self.rejections.append(code)
            if len(self.rejections) >= 2:
                blocked = all(item.startswith("admission_") for item in self.rejections)
                raise GuardStop("repeated_pre_dispatch_rejection",
                                "rejected before dispatch: %s" % ", ".join(self.rejections),
                                reply.seq, blocked=blocked)
