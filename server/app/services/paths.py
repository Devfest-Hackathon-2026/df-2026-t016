"""Cloud Storage のパス（共通仕様6章）。"""


def start(sid: str) -> str:
    return f"sessions/{sid}/start.json"


def chunk(sid: str, seq: int) -> str:
    return f"sessions/{sid}/chunks/{seq:06d}.json"


def receipt(sid: str, seq: int) -> str:
    return f"sessions/{sid}/receipts/{seq:06d}.json"


def image(sid: str, sha: str) -> str:
    return f"sessions/{sid}/images/{sha}.jpg"
