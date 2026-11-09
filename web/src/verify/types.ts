// 証拠一式（共通仕様7章）と検証の結果（tasks/T09）の型。

export type Signed = { bytes: string; sig: string };

export type BundleChunk = { header: string; sig: string; body: string; receipt: string; receiptSig: string };

export type BundleFiles = { start: string | null; end: string | null; png: string | null; whole?: (string | null)[] | null };

/** 1回の記録の開始証とチャンク（【T14】v:2 の sessions の要素） */
export type BundleSession = { start: Signed; chunks: BundleChunk[] };

type Explanation = { text: string; model: string; links?: { from: number; to: number }[] };

export type BundleV1 = {
  v: 1;
  manifest: Signed;
  start: Signed;
  chunks: BundleChunk[];
  files: BundleFiles;
  kms: { publicKeyPem: string; keyVersion: string };
  explanation: Explanation | null;
};

/** 【T14】記録が複数になった形。sessions は確定記録の sessions と同じ順 */
export type BundleV2 = {
  v: 2;
  manifest: Signed;
  sessions: BundleSession[];
  files: BundleFiles;
  kms: { publicKeyPem: string; keyVersion: string };
  explanation: Explanation | null;
};

export type Bundle = BundleV1 | BundleV2;

// session は【T14】v:2 の全記録をまとめた一覧（VerifyResult.reception.gaps）だけ
export type Gap = { session?: number; after: number; sec: number };

export type WholeLink = { result: "linked" | "unconfirmed"; kept: number | null; reason: string | null };

export type ManifestWhole = {
  shown: boolean;
  // session は【T14】v:2 だけ（sessions の番号）
  items: { session?: number; seq: number; sha256: string; received: boolean; canvas: { x: number; y: number; w: number; h: number } | null }[];
  links: ({ from: number; to: number } & WholeLink)[];
  toPng: WholeLink | null;
};

export type MatchResult = { result: "match" | "mismatch" | "unverified"; score: number | null; reason: string | null };

/** 1回の記録の結果（v:1 では確定記録の直下、【T14】v:2 では sessions の要素） */
export type ManifestSession = {
  sid: string;
  status: "completed" | "aborted";
  chunks: { count: number; first: string | null; last: string | null };
  received: { first: string | null; last: string | null; gaps: Gap[] };
};

type ManifestCommon = {
  type: "manifest";
  rules: string;
  workId: string;
  title: string;
  displayName: string;
  images: { start: string | null; end: string | null };
  png: { sha256: string; width: number; height: number } | null;
  match: MatchResult;
  // 【11/8】版2は aiUse（none・partial・major）と detail（作者が書いた詳細）を持つ
  declaration: { version: number; text: string; acceptedAt: string; aiUse?: "none" | "partial" | "major"; detail?: string };
  whole?: ManifestWhole | null;
  rejected: number;
  createdAt: string;
};

export type ManifestV1 = ManifestCommon & ManifestSession & { v: 1 };
export type ManifestV2 = ManifestCommon & { v: 2; sessions: ManifestSession[] };
export type Manifest = ManifestV1 | ManifestV2;

/** 画面と検証で使う形。v:1 は記録が1回の v:2 として読む（normalizeManifest） */
export type NormManifest = ManifestCommon & { v: 1 | 2; sessions: ManifestSession[] };

export type StartCert = {
  v: 1;
  type: "start";
  sid: string;
  workId: string;
  devicePubKey: string;
  checked: string[];
  issuedAt: string;
};

export type ProblemKind = "signature" | "chain" | "hash" | "count" | "key" | "gap" | "image" | "missing";

export type IntegrityStatus =
  | "ok"
  | "incomplete"
  | "signature_mismatch"
  | "content_mismatch"
  | "chain_broken"
  | "manifest_mismatch";

// session は【T14】v:2 だけ（何回目の記録か。0から）
export type Problem = { session?: number; seq?: number; kind: ProblemKind; detail: string };

/** 1回の記録の受信状況（【T14】v:2 だけ） */
export type SessionReception = {
  sid: string;
  status: "completed" | "aborted";
  first: string | null;
  last: string | null;
  gaps: Gap[];
  activeChunks: boolean[];
  editorMs: number | null;
  activeMs: number | null;
};

export type ImageState = "ok" | "mismatch" | "missing" | "none"; // none = 記録されていない

export type VerifyResult = {
  integrity: { status: IntegrityStatus; problems: Problem[] };
  reception: {
    status: "completed" | "aborted";
    first: string | null;
    last: string | null;
    gaps: Gap[];
    activeChunks: boolean[]; // 各チャンクの frames の合計が0より大きいか
    // 【11/6】Procreate の編集画面だった時間と、そのうちキャンバスに小さな変化があった時間（ミリ秒、ヘッダの stats の合計）。
    // ヘッダに項目が無い記録（11/6 より前）では null
    editorMs: number | null;
    activeMs: number | null;
    // 全記録の frames と fps から換算した大きな変化の時間。集計に必要な記録がそろわない場合は null。
    largeChangeMs: number | null;
    // 【T14】v:2 だけ。上の項目は全記録をまとめたもの（status はすべて正常終了なら completed、gaps は session 付きで並べる）
    sessions?: SessionReception[];
  };
  images: { start: ImageState; end: ImageState };
  match: MatchResult;
  declaration: { text: string; acceptedAt: string } | null;
  unverified: string[]; // 未確認事項として出す文
  whole: {
    shown: boolean;
    // minutes: 受信開始からの分。none = 届いていない、hidden = 載せない設定、pending = 確かめ中
    // minutes は【T14】v:2 ではその記録の受信開始からの分。session は v:2 だけ
    items: { session?: number; seq: number; minutes: number; status: WholeItemState }[];
    links: ({ from: number; to: number } & WholeLink)[];
    toPng: WholeLink | null;
  } | null;
};

export type WholeItemState = "ok" | "mismatch" | "missing" | "none" | "hidden" | "pending";
