import m from "mithril";
import { PerfettoPlugin } from "../../public/plugin";
import { Trace } from "../../public/trace";
import { TrackNode } from "../../public/workspace";
import { NUM, STR } from "../../trace_processor/query_result";
import { Time } from "../../base/time";
import { HighPrecisionTimeSpan } from "../../base/high_precision_time_span";
import {epochBands, epochOverlay} from './epoch_bands';
import {participants, participantFacts, participantTrack, receiptOverlay, symbols, type Fact} from './participants';

// All protocol calculations and bindings come from Go. These types describe
// presentation rows; no quorum or identity reconstruction is performed here.
type Row = { [key: string]: any };
const names = ["overview", "round", "membership", "evidence"];
const label = (v: unknown) =>
  v === null || v === undefined ? "unknown" : String(v);
const button = (text: string, action: () => void) =>
  m("button", { onclick: action, style: "margin:3px;padding:5px 9px" }, text);
function table(headers: string[], rows: m.Children[][]) {
  return m(
    "table",
    { style: "border-collapse:collapse;width:100%;margin:10px 0" },
    [
      m(
        "thead",
        m(
          "tr",
          headers.map((h) =>
            m(
              "th",
              {
                style:
                  "text-align:left;padding:7px;border-bottom:2px solid #91a4b9",
              },
              h,
            ),
          ),
        ),
      ),
      m(
        "tbody",
        rows.map((row) =>
          m(
            "tr",
            row.map((cell) =>
              m(
                "td",
                {
                  style:
                    "padding:7px;border-bottom:1px solid #d8dfe8;vertical-align:top;overflow-wrap:anywhere",
                },
                cell,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
export default class GonkaConsensus implements PerfettoPlugin {
  static readonly id = "net.gonka.Consensus";
  private data!: Row;
  private state!: Row;
  private trace!: Trace;
  private viewUrl = "";
  private timer: ReturnType<typeof setTimeout> | undefined;
  private error = "";
  private search = "";
  private historyPage = 0;
  private coveragePage = 0;
  private eventByID = new Map<string, Row>();
  private actorByID = new Map<string, Row>();
  private heights: number[] = [];
  private workspace!: ReturnType<Trace["workspaces"]["createEmptyWorkspace"]>;
  private participantWorkspace!: ReturnType<Trace["workspaces"]["createEmptyWorkspace"]>;
  private diagnostic = false;
  private selectedFacts: Fact[] = [];
  private selectedFactEvents = new Set<string>();
  private factPage = 0;

  async onTraceLoad(trace: Trace, args?: Row) {
    if (!args?.analysisUrl) return;
    this.trace = trace;
    try {
      const url = new URL(String(args.analysisUrl), location.origin);
      if (
        url.origin !== location.origin ||
        !url.pathname.startsWith("/api/session/")
      )
        throw Error("Nonlocal analysis URL");
      const response = await fetch(url);
      if (!response.ok) throw Error("Analysis unavailable");
      this.data = await response.json();
      for (const key of [
        "actors",
        "bindings",
        "events",
        "observations",
        "validator_sets",
        "membership_changes",
        "certificates",
        "round_summaries",
        "measurements",
        "coverage",
        "findings",
      ])
        this.data[key] ??= [];
      this.eventByID = new Map(this.data.events.map((e: Row) => [e.event_id, e]));
      this.actorByID = new Map(this.data.actors.map((a: Row) => [a.id, a]));
      trace.tracks.registerOverlay(epochOverlay(epochBands(this.data.events)));
      const facts = participantFacts(this.data);
      this.participantWorkspace = trace.workspaces.createEmptyWorkspace('Gonka participants', 'gonka-participants');
      for (const node of participants) {
        const uri = 'gonka/participant/'+node;
        trace.tracks.registerTrack({uri, renderer: participantTrack(facts.filter(f=>f.node===node), selected=>{
          this.selectedFacts = selected;
          this.factPage = 0;
          this.selectedFactEvents = new Set(selected.flatMap(f=>f.events));
          this.state.event_id = '';
          this.state.height = selected[0].height;
          this.search = '';
          this.navigate('evidence');
        })});
        this.participantWorkspace.addChildLast(new TrackNode({name:node,uri}));
      }
      trace.tracks.registerOverlay(receiptOverlay(()=>this.diagnostic?[]:this.selectedFacts, facts));
      this.heights = this.data.validator_sets.map((s: Row) => s.height);
      this.state = args.viewState;
      this.viewUrl = String(args.viewUrl);
      if (new URL(this.viewUrl, location.origin).origin !== location.origin)
        throw Error("Nonlocal view URL");
      if (
        this.data.meta.schema !== "gonka.analysis.v1" ||
        this.data.meta.fingerprint !== args.datasetId ||
        this.state.fingerprint !== args.datasetId
      )
        throw Error("Incompatible analysis or view");
      const marker = await trace.engine.query(
        "SELECT extract_arg(arg_set_id, 'debug.gonka_fingerprint') AS fingerprint, extract_arg(arg_set_id, 'debug.gonka_schema') AS schema FROM slice WHERE name = 'Gonka incident metadata'",
      );
      const it = marker.iter({ fingerprint: STR, schema: STR });
      if (!it.valid() || it.fingerprint !== args.datasetId || it.schema !== this.data.meta.schema)
        throw Error("Trace/analysis fingerprint mismatch");
      await trace.engine.query(
        "CREATE VIEW gonka_events AS SELECT id, ts, dur, track_id, name, extract_arg(arg_set_id, 'debug.gonka_event_id') AS event_id, extract_arg(arg_set_id, 'debug.gonka_height') AS height, extract_arg(arg_set_id, 'debug.gonka_round') AS round, extract_arg(arg_set_id, 'debug.gonka_phase') AS phase FROM slice WHERE extract_arg(arg_set_id, 'debug.gonka_event_id') IS NOT NULL",
      );
      await trace.engine.query(
        "CREATE VIEW gonka_power_samples AS SELECT c.ts,c.value,t.name,t.id AS track_id FROM counter c JOIN counter_track t ON t.id=c.track_id WHERE t.name GLOB 'Evidence points*'",
      );
      for (const name of names) {
        trace.tabs.registerTab({
          uri: "gonka/" + name,
          content: {
            getTitle: () => "Gonka · " + name,
            render: () => this.render(name),
          },
        });
        trace.tabs.addDefaultTab("gonka/" + name);
      }
      trace.commands.registerCommand({
        id: "net.gonka.Consensus.ApplyPreset",
        name: "Gonka: Apply investigation preset",
        callback: () => this.applyPreset(),
      });
      trace.trash.use(
        trace.onTraceReady.addListener(() => {
          this.selectRange(String(args.initialRange ?? "incident"));
          this.applyPreset();
          if (Number.isSafeInteger(args.initialHeight) && args.initialHeight >= this.data.meta.from && args.initialHeight <= this.data.meta.to + 1) {
            this.state.height = args.initialHeight;
            this.focusHeight();
            this.captureView();
          }
          window.parent.postMessage(
            { gonkaReady: args.datasetId },
            location.origin,
          );
        }),
      );
      const rangeMessage = (event: MessageEvent) => {
        if (event.origin !== location.origin || event.source !== window.parent || event.data?.gonkaDataset !== args.datasetId) return;
        if (["incident", "node2", "all", "saved"].includes(event.data.gonkaRange)) {
          this.selectRange(event.data.gonkaRange);
          m.redraw();
        }
      };
      window.addEventListener("message", rangeMessage);
      const poll = setInterval(() => this.captureView(), 1500);
      trace.trash.defer(() => {
        window.removeEventListener("message", rangeMessage);
        clearInterval(poll);
        if (this.timer) clearTimeout(this.timer);
      });
    } catch (e) {
      this.error = String(e);
      trace.tabs.registerTab({
        uri: "gonka/error",
        content: {
          getTitle: () => "Gonka load error",
          render: () => m("pre", this.error),
        },
      });
      trace.tabs.showTab("gonka/error");
      window.parent.postMessage({ gonkaError: this.error }, location.origin);
    }
  }
  private selectRange(range: string) {
    if (range === "saved") return;
    const end = BigInt(this.data.meta.end_ns);
    let start = end > 600000000000n ? end - 600000000000n : 0n;
    let stop = end;
    this.state.height = this.data.meta.focus_height;
    if (range === "node2") {
      start = 0n;
      stop = 1n;
      this.state.height = this.data.meta.from;
      for (const e of this.data.events) {
        if (e.height <= this.data.meta.from + 139 && e.trace_ts_ns !== undefined) {
          const t = BigInt(e.trace_ts_ns) + 1000000000n;
          if (t > stop) stop = t;
        }
      }
    } else if (range === "all") start = 0n;
    this.state.viewport_ns = [String(start), String(stop)];
    this.state.preset = "overview";
    this.state.event_id = "";
    this.state.round_id = "";
    this.state.round = 0;
    if (this.workspace) this.applyPreset();
    this.save();
  }
  private applyPreset() {
    if (!this.workspace) {
      this.workspace = this.trace.workspaces.createEmptyWorkspace(
        "Gonka investigation",
        "gonka",
      );
      const groups = new Map<string, TrackNode>();
      for (const track of this.trace.tracks.getAllTracks()) {
        // Counter points are available through SQL and the Gonka panel, not
        // pinned as falsely continuous lines across source gaps.
        if (track.pluginId !== "dev.perfetto.TrackEvent") continue;
        const existing = this.trace.defaultWorkspace.getTrackByUri(track.uri);
        if (!existing || existing.name.startsWith("Evidence points")) continue;
        // Native participant parents are containers, not extra event tracks.
        if (/^node\d+(?:-\d+)?$/.test(existing.name)) continue;
        if (
          this.state.track_uris?.length &&
          !this.state.track_uris.includes(track.uri)
        )
          continue;
        const participant = existing.name.match(/^(?:Voting power \/ )?(node\d+(?:-\d+)?) · /)?.[1];
        const groupName = participant ?? (existing.name.startsWith("Voting power /")
          ? "Voting power (height samples)"
          : existing.name.startsWith("signer@")
          ? "Signers"
          : existing.name.startsWith("application@")
            ? "Application"
            : /^(core|state)@/.test(existing.name)
              ? "Nodes"
              : "Network");
        let group = groups.get(groupName);
        if (!group) {
          group = new TrackNode({
            name: groupName,
            collapsed: this.state.collapsed?.[groupName] ?? false,
          });
          groups.set(groupName, group);
          this.workspace.addChildLast(group);
        }
        group.addChildLast(
          new TrackNode({ name: existing.name, uri: track.uri }),
        );
      }
    }
    this.trace.workspaces.switchWorkspace(this.diagnostic ? this.workspace : this.participantWorkspace);
    if (this.state.viewport_ns?.length === 2) {
      this.trace.timeline.setVisibleWindow(
        HighPrecisionTimeSpan.fromTime(
          Time.fromRaw(BigInt(this.state.viewport_ns[0])),
          Time.fromRaw(BigInt(this.state.viewport_ns[1])),
        ),
      );
    } else this.focusHeight();
    this.trace.tabs.showTab("gonka/" + this.state.preset);
    if (this.state.event_id) void this.selectEvent(this.state.event_id, false);
  }
  private focusHeight() {
    const events = this.data.events.filter(
      (e: Row) =>
        e.trace_ts_ns !== undefined &&
        e.height >= this.state.height - 3 &&
        e.height <= this.state.height,
    );
    if (!events.length) return;
    const times = events.map((e: Row) => BigInt(e.trace_ts_ns));
    const start = times.reduce((x: bigint, y: bigint) => (x < y ? x : y));
    const end =
      times.reduce((x: bigint, y: bigint) => (x > y ? x : y)) + 1000000000n;
    this.trace.timeline.setVisibleWindow(
      HighPrecisionTimeSpan.fromTime(Time.fromRaw(start), Time.fromRaw(end)),
    );
  }
  private captureView() {
    if (!this.workspace) return;
    const visiblePanel = [...document.querySelectorAll<HTMLElement>("[data-gonka-view]")].find(el=>el.getClientRects().length>0);
    const preset = visiblePanel?.dataset.gonkaView ?? this.state.preset;
    const window = this.trace.timeline.visibleWindow;
    const viewport = [
      window.start.toTime().toString(),
      window.end.toTime().toString(),
    ];
    const collapsed: Row = {};
    for (const g of this.workspace.children) collapsed[g.name] = g.collapsed;
    const tracks = this.workspace.children.flatMap((g) =>
      g.children.map((t) => t.uri).filter(Boolean),
    );
    if (
      JSON.stringify(viewport) !== JSON.stringify(this.state.viewport_ns) ||
      JSON.stringify(collapsed) !== JSON.stringify(this.state.collapsed) ||
      JSON.stringify(tracks) !== JSON.stringify(this.state.track_uris) || preset!==this.state.preset
    ) {
      this.state.viewport_ns = viewport;
      this.state.collapsed = collapsed;
      this.state.track_uris = tracks;
      this.state.preset = preset;
      this.save();
    }
  }
  private save() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      void fetch(this.viewUrl, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(this.state),
      })
        .then((r) => {
          if (!r.ok) throw Error("View save failed: " + r.status);
        })
        .catch((e) => {
          this.error = String(e);
          m.redraw();
        });
    }, 250);
  }
  private navigate(preset: string, values: Row = {}) {
    if ('event_id' in values) {this.selectedFacts=[];this.selectedFactEvents.clear();}
    Object.assign(this.state, values, { preset });
    this.save();
    this.trace.tabs.showTab("gonka/" + preset);
    m.redraw();
  }
  private async selectEvent(id: string, evidence = true) {
    this.selectedFacts = [];
    this.selectedFactEvents.clear();
    const e = this.eventByID.get(id);
    if (!e) return;
    this.state.event_id = id;
    if (e.trace_ts_ns !== undefined && /^[a-f0-9]+$/.test(id)) {
      const result = await this.trace.engine.query(
        "SELECT id FROM gonka_events WHERE event_id='" + id + "' LIMIT 1",
      );
      const row = result.iter({ id: NUM });
      if (row.valid())
        this.trace.selection.selectSqlEvent("slice", row.id, {
          scrollToSelection: true,
        });
    }
    if (evidence) this.navigate("evidence");
    else this.save();
  }
  private controls() {
    const select = (key: string, values: string[]) =>
      m(
        "select",
        {
          value: this.state[key] ?? "",
          onchange: (e: Event) => {
            this.state[key] = (e.target as HTMLSelectElement).value;
            this.save();
            m.redraw();
          },
        },
        values.map((x) => m("option", { value: x }, x || "all")),
      );
    const targets = [
      ...new Set<string>(
        this.data.round_summaries
          .filter(
            (r: Row) =>
              r.height === this.state.height && r.round === this.state.round,
          )
          .flatMap((r: Row) => r.tallies.map((t: Row) => String(t.target))),
      ),
    ];
    return m("div", [
      button(this.diagnostic ? 'Participants: 7 lanes' : 'Diagnostic sources', () => {this.diagnostic=!this.diagnostic;this.applyPreset();}),
      ...names.map((x) => button(x, () => this.navigate(x))),
      m("label", " Height "),
      m("input[type=number]", {
          min: this.data.meta.from,
          max: this.data.meta.to + 1,
          step: 1,
          style: "width:110px",
          "aria-label": "Height",
          value: this.state.height,
          onchange: (e: Event) => {
            const h = Number((e.target as HTMLInputElement).value);
            if (!Number.isSafeInteger(h) || h < this.data.meta.from || h > this.data.meta.to + 1) return;
            this.state.height = h;
            this.state.round_id = "";
            this.state.target = "";
            this.focusHeight();
            this.save();
          },
        }),
      button("Previous retained H", () => this.moveHeight(-1)),
      button("Next retained H", () => this.moveHeight(1)),
      m("label", " Round "),
      m("input[type=number]", {
        min: 0,
        value: this.state.round,
        style: "width:60px",
        onchange: (e: Event) => {
          this.state.round = Number((e.target as HTMLInputElement).value);
          this.state.round_id = "";
          this.save();
        },
      }),
      select("type", ["", "PREVOTE", "PRECOMMIT"]),
      select("target", ["", ...targets]),
      m("span", this.error),
    ]);
  }
  private moveHeight(direction: number) {
    const candidates = this.heights.filter(h => direction < 0 ? h < this.state.height : h > this.state.height);
    const h = direction < 0 ? candidates[candidates.length - 1] : candidates[0];
    if (h === undefined) return;
    this.state.height = h;
    this.state.round_id = "";
    this.state.target = "";
    this.focusHeight();
    this.save();
  }
  private coverage() {
    const count = this.data.coverage.length;
    const pages = Math.max(1, Math.ceil(count / 50));
    this.coveragePage = Math.min(this.coveragePage, pages - 1);
    return [
      m("p", `${count} coverage / collection-attempt notes; page ${this.coveragePage + 1} of ${pages}`),
      button("Previous notes", () => { this.coveragePage = Math.max(0, this.coveragePage - 1); }),
      button("Next notes", () => { this.coveragePage = Math.min(pages - 1, this.coveragePage + 1); }),
      m("ul", this.data.coverage.slice(this.coveragePage * 50, (this.coveragePage + 1) * 50).map((s: string) => m("li", s))),
    ];
  }
  private actorName(id: string) {
    const actor = this.actorByID.get(id);
    return actor ? m("span", {title: id + " · " + (actor.label_basis ?? "")}, actor.label) : label(id);
  }
  private render(view: string) {
    return m(
      "section",
      {
        style:
          "padding:16px;overflow:auto;max-height:70vh;font:14px system-ui;color:#182d43;background:#f7f9fc",
        "data-gonka-view": view,
      },
      [
        m("h2", this.data.meta.incident + " · " + view),
        this.controls(),
        m(
          "p",
          "Retained evidence, not live network health · " +
            this.data.meta.input_kind +
            " · UTC origin " +
            this.data.meta.utc_origin,
        ),
        view === "overview"
          ? this.overview()
          : view === "round"
            ? this.round()
            : view === "membership"
              ? this.membership()
              : this.evidence(),
      ],
    );
  }
  private overview() {
    const h = this.data.meta.focus_height;
    const changes = this.data.membership_changes.filter(
      (c: Row) => c.stage !== "retained",
    );
    const rounds = this.data.round_summaries.filter(
      (r: Row) => r.height === h && r.temporality === "snapshot",
    );
    return [
      m(
        "h3",
        "Last retained committed height " +
          this.data.meta.to +
          " · investigate H" +
          h,
      ),
      m("p", '△ proposal observed · ○ prevote signed · ● precommit signed · ? inferred signer binding · ✓ commit-certificate signature · ▣ block execution · ◩ finalizing · ⚑ epoch · ↕ power change · ⊠ jail · ⇥ received vote · ⊞ visual cluster'),
      m("p", 'Seven participant lanes; click a symbol to inspect all supporting evidence. A number counts facts in a visual cluster, not votes or voting power. Missing events do not prove downtime. Selecting one certificate signature links signatures for the same block without arrows; this is agreement, not message delivery. Receipt arrows require known endpoints; send time is not reconstructed.'),
      m("details", [m("summary", 'Attribution and evidence limits'),m("p", this.data.findings.join(" · "))]),
      button("Open vote matrix", () => this.navigate("round", { height: h })),
      button("Last commit certificates", () =>
        this.navigate("evidence", { height: this.data.meta.to, event_id: "" }),
      ),
      button("Coverage gaps", () => {
        this.search = "";
        this.navigate("evidence");
      }),
      button("Full historical range", () => {
        if (window.confirm("Show the entire history? Rendering may be slower; use Incident to return to a small window.")) this.selectRange("all");
      }),
      button("Incident: last 10 minutes", () => this.selectRange("incident")),
      button("Node2: first two epochs", () => this.selectRange("node2")),
      ...rounds
        .slice(0, 1)
        .map((r: Row) =>
          m("div", [
            m("h3", "Later snapshot · " + r.observer + " · " + r.collected_at),
            this.tallies(r),
          ]),
        ),
      m("h3", "Membership history (entire input range)"),
      m("p", "Epoch shading: alternating light/grey bands between retained adjacent epoch changes (70 blocks). Labels use start height, not epoch number. Uncovered ranges are unshaded; the final band ends at the last retained block, not at later RPC snapshots."),
      m("p", "Voting-power tracks show complete V(H) samples, not signer availability; header times anchor heights, not exact activation times."),
      m("p", `${changes.length} changes; page ${this.historyPage + 1} of ${Math.max(1, Math.ceil(changes.length / 200))}`),
      button("Previous changes", () => { this.historyPage = Math.max(0, this.historyPage - 1); }),
      button("Next changes", () => { this.historyPage = Math.min(Math.max(0, Math.ceil(changes.length / 200) - 1), this.historyPage + 1); }),
      table(
        ["Height", "Identity", "Power", "Stage", "Explore"],
        changes.slice(this.historyPage * 200, (this.historyPage + 1) * 200).map((c: Row) => [
          c.height,
          this.actorName(c.validator_id),
          label(c.old_power) + " → " + label(c.new_power),
          c.stage,
          button("key history", () =>
            this.navigate("membership", {
              validator: c.validator_id,
              height: c.height,
            }),
          ),
        ]),
      ),
      m("h3", "Jail for missed signatures"),
      table(
        ["Height", "UTC / time basis", "Validator", "Observer", "Evidence"],
        this.data.events.filter((e: Row) => e.kind === "validator.jailed.liveness").map((e: Row) => [
          e.height, label(e.occurred_at) + " / " + e.time_basis,
          this.actorName(e.validator_id), e.observer_id,
          button("source", () => this.navigate("evidence", {height: e.height, event_id: e.event_id})),
        ]),
      ),
      m("h3", "Source coverage"),
      this.coverage(),
    ];
  }
  private tallies(r: Row) {
    const ts = r.tallies.filter(
      (t: Row) =>
        (!this.state.type || t.type === this.state.type) &&
        (!this.state.target || t.target === this.state.target),
    );
    return table(
      [
        "Type / target",
        "P (incl. inferred)",
        "P observed only",
        "T / Q",
        "Deficit",
        "Unrepresented",
        "Unresolved",
        "Condition",
      ],
      ts.map((t: Row) => [
        t.type + " / " + t.target,
        [
          label(t.power),
          t.power !== null && t.quorum > 0
            ? m("meter", {
                min: 0,
                max: t.quorum,
                value: t.power,
                title: "Evidence P / quorum Q",
                style: "display:block;width:100px",
              })
            : null,
        ],
        label(t.observed_only_power),
        label(t.total) + " / " + label(t.quorum),
        label(t.deficit),
        label(t.unrepresented),
        t.unresolved,
        t.condition + " · " + t.assessment,
      ]),
    );
  }
  private round() {
    const rs = this.data.round_summaries.filter(
      (r: Row) =>
        r.height === this.state.height && r.round === this.state.round,
    );
    const current =
      rs.find((r: Row) => r.id === this.state.round_id) ??
      rs.find((r: Row) => r.temporality === "snapshot") ??
      rs[0];
    return [
      m(
        "select",
        {
          value: current?.id,
          onchange: (e: Event) => {
            this.state.round_id = (e.target as HTMLSelectElement).value;
            this.save();
          },
        },
        rs.map((r: Row) =>
          m(
            "option",
            { value: r.id },
            r.measurement_basis +
              " · " +
              r.observer +
              " · " +
              (r.collected_at || r.temporality),
          ),
        ),
      ),
      current
        ? [
            m(
              "p",
              current.measurement_basis +
                " · " +
                current.observer +
                " · " +
                current.temporality +
                " " +
                (current.collected_at || "") +
                " · step " +
                (current.state || "unknown"),
            ),
            this.tallies(current),
            table(
              [
                "Consensus identity / actor",
                "Power",
                "Binding",
                "Proposal",
                "Prevote",
                "Precommit",
                "Sources",
              ],
              (current.rows ?? []).map((r: Row) => [
                this.actorName(r.validator_id ?? r.actor_id),
                label(r.power),
                r.identity_basis,
                ...["proposal", "prevote", "precommit"].map((k) =>
                  (r[k] ?? []).length
                    ? (r[k].length > 1 ? "conflict: " : "") + r[k].join(", ")
                    : current.measurement_basis === "commit_certificate" &&
                        k === "precommit"
                      ? "absent in this certificate"
                      : "not observed in selected evidence",
                ),
                button("evidence", () => {
                  if (r.event_ids.length) void this.selectEvent(r.event_ids[0]);
                }),
              ]),
            ),
            m(
              "h3",
              "Historical signing evidence points (no inferred reception curve)",
            ),
            table(
              ["Time", "P", "Basis", "Unresolved"],
              this.data.measurements
                .filter(
                  (x: Row) =>
                    x.height === this.state.height &&
                    x.round === this.state.round &&
                    x.trace_ts_ns !== undefined,
                )
                .map((x: Row) => [
                  x.as_of,
                  label(x.value),
                  x.measurement_basis + " / " + x.identity_basis,
                  x.unresolved_signatures,
                ]),
            ),
          ]
        : m("p", "No round evidence for this selection"),
    ];
  }
  private membership() {
    const rows = this.data.membership_changes.filter(
      (r: Row) =>
        (!this.state.validator || r.validator_id === this.state.validator) && (r.stage !== "retained" || r.height === this.state.height),
    );
    const page = Math.min(this.historyPage, Math.max(0, Math.ceil(rows.length / 200) - 1));
    return [
      m("p", "Changes cover the entire input range; retained rows show the selected height"),
      m("p", `${rows.length} changes; page ${page + 1} of ${Math.max(1, Math.ceil(rows.length / 200))}`),
      button("Previous changes", () => { this.historyPage = Math.max(0, page - 1); }),
      button("Next changes", () => { this.historyPage = Math.min(Math.max(0, Math.ceil(rows.length / 200) - 1), page + 1); }),
      m("input", {
        placeholder: "full validator ID",
        value: this.state.validator ?? "",
        oninput: (e: Event) => {
          this.state.validator = (e.target as HTMLInputElement).value;
          this.save();
        },
      }),
      button("All identities", () => {
        this.state.validator = "";
        this.save();
      }),
      table(
        [
          "Effective H",
          "Identity",
          "Old → new power",
          "Stage",
          "Emitted H / distance",
          "Source",
        ],
        rows.slice(page * 200, (page + 1) * 200).map((r: Row) => [
          r.height,
          this.actorName(r.validator_id),
          label(r.old_power) + " → " + label(r.new_power),
          r.stage,
          (r.emitted_height || "unknown") +
            " / " +
            label(r.activation_distance),
          button("open H / evidence", () => {
            this.state.height = r.height;
            this.search = r.validator_id;
            this.focusHeight();
            this.navigate("evidence");
          }),
        ]),
      ),
      m(
        "h3",
        "Actor bindings at selected height (not permanent key ownership)",
      ),
      table(
        ["Actor", "Identity", "H / R", "Basis / source"],
        this.data.bindings
          .filter(
            (b: Row) => b.height === this.state.height && (!this.state.validator || b.to === this.state.validator),
          )
          .map((b: Row) => [
            this.actorName(b.from),
            this.actorName(b.to),
            b.height + " / " + b.round,
            b.basis + " " + b.reason,
          ]),
      ),
      m("h3", "Unobserved stages"),
      m(
        "p",
        "JOIN key selection, transaction inclusion and historical generation binding require their own sources; active membership does not prove those stages",
      ),
    ];
  }
  private evidence() {
    let rows = this.data.observations.filter((o: Row) => {
      return (
        (!this.selectedFacts.length || this.selectedFactEvents.has(o.event_id)) &&
        (!this.state.event_id || o.event_id === this.state.event_id) &&
        (!this.search ||
          JSON.stringify([o, this.eventByID.get(o.event_id)])
            .toLowerCase()
            .includes(this.search.toLowerCase()))
      );
    });
    const count = rows.length;
    rows = rows.slice(0, 150);
    return [
      this.selectedFacts.length ? m('p', `${this.selectedFacts.length} facts in the selected visual cluster; page ${this.factPage+1}`) : null,
      this.selectedFacts.length>50 ? [
        button('Previous facts',()=>{this.factPage=Math.max(0,this.factPage-1);}),
        button('Next facts',()=>{this.factPage=Math.min(Math.ceil(this.selectedFacts.length/50)-1,this.factPage+1);}),
      ] : null,
      ...this.selectedFacts.slice(this.factPage*50,(this.factPage+1)*50).map(f=>m('details', {open:true}, [
        m('summary', `${symbols[f.kind]} ${f.node} · H${f.height} R${f.round} · ${f.detail}`),
        m('p', `${f.events.length} retained event records; ${f.refs.length} source references; timestamp range ${f.ts}–${f.last} ns from trace origin`),
        m('pre', {style:'white-space:pre-wrap'}, f.refs.join('\n')),
      ])),
      button("All evidence", () => {
        this.selectedFacts = [];
        this.selectedFactEvents.clear();
        this.state.event_id = "";
        this.search = "";
        this.save();
      }),
      m("input", {
        placeholder: "event / actor / height / source",
        value: this.search,
        oninput: (e: Event) => {
          this.search = (e.target as HTMLInputElement).value;
        },
      }),
      m("p", count + " observations; first 150 shown"),
      ...rows.map((o: Row) =>
        m("details", [
          m(
            "summary",
            o.source_kind +
              " · " +
              o.observer_id +
              " · collected " +
              (o.collected_at || "unknown") +
              " · " +
              o.source_ref,
          ),
          m(
            "p",
            "Observed/signature timestamp: " +
              (o.observed_at || "unknown") +
              " · original available: " +
              o.original_available,
          ),
          m(
            "pre",
            { style: "white-space:pre-wrap" },
            o.excerpt || JSON.stringify(o.attributes, null, 2),
          ),
        ]),
      ),
      m("h3", "Certificate variants H" + this.state.height),
      table(
        ["Block", "Signers", "Power / Q", "Observers", "Variant basis"],
        this.data.certificates
          .filter((c: Row) => c.height === this.state.height)
          .map((c: Row) => [
            c.block_id,
            c.signers.join(", "),
            label(c.power) + " / " + label(c.quorum),
            c.observers.join(", "),
            c.variant_basis + "; " + c.verification,
          ]),
      ),
      m("h3", "Coverage gaps"),
      this.coverage(),
    ];
  }
}
