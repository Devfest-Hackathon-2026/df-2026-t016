"""前後の途中画像を Gemini に渡し、見返す箇所の注意点を作る。"""

from __future__ import annotations

import json
from datetime import timedelta, timezone

from ..core.text import clean
from .review import ReviewPair

PROMPT = """画像Aは前、画像Bは後の制作スナップショットです。
最初に、両方に残っている人物や背景の線・輪郭を見比べてください。

細部まで描き込まれた主要な部分が新しく現れたり、大きく置き換わったりしている場合は、残っている線や構図と、前後の受信間隔をあわせて見てください。
線や形のつながりから自然な描き進め方と読める場合は該当なしとし、つながりを追いにくい大きな変化が画像に見える場合だけ、見返す箇所を1件挙げてください。
具体的な部位と、線・形・細部がどう変わったかを画像に沿って書いてください。

受信間隔は、2枚を含む記録が届いた時刻の差で、制作にかけた時間は分かりません。間隔の長さで対象を外さず、受信の空きや間隔の長さだけを理由に注意点を挙げないでください。

拡大・回転、単色の塗り、既存の輪郭に沿った色や影の変更、地面や背景色の塗り足し、白紙から線画が現れただけの場合は空の配列を返してください。
例: ドアと人物の輪郭が残り、白い背景と顔の白い部分が同じ色に変わっただけなら、該当なしです。
変化の内容を見分けられない場合も該当なしです。

注意点には、画像で見える変化と、2枚の間で画像から追えない工程を簡潔に書いてください。
画像の間で何をしたか、素材の出どころ、AI利用の有無は推測しないでください。
受信時刻は表示側で添えます。文章には時刻や画像番号を書かないでください。
該当なしは {"observations":[]} です。
"""

SCHEMA = {
    "type": "OBJECT",
    "required": ["observations"],
    "properties": {
        "observations": {
            "type": "ARRAY",
            "maxItems": 1,
            "items": {
                "type": "OBJECT",
                "required": ["change", "review"],
                "properties": {"change": {"type": "STRING"}, "review": {"type": "STRING"}},
            },
        },
    },
}
JST = timezone(timedelta(hours=9))


class GeminiExplainer:
    def __init__(
        self, project: str, location: str, model: str, timeout_sec: float = 35.0,
        *, credentials=None, attempts: int = 1,
    ):
        from google import genai
        from google.genai import types

        self._types = types
        self._model = model
        self._client = genai.Client(
            vertexai=True,
            project=project,
            location=location,
            credentials=credentials,
            http_options=types.HttpOptions(
                api_version="v1",
                timeout=int(timeout_sec * 1000),
                retry_options=types.HttpRetryOptions(attempts=attempts, http_status_codes=[429]),
            ),
        )

    def __call__(self, pairs: list[ReviewPair]) -> dict:
        notes = []
        links = []
        t = self._types
        config = t.GenerateContentConfig(response_mime_type="application/json", response_schema=SCHEMA)
        if self._model == "gemini-3.8-flash":
            config.thinking_config = t.ThinkingConfig(thinking_level="LOW")
        for pair in pairs:
            elapsed = round((pair.end - pair.start).total_seconds())
            gap = f"最長で約{round(pair.max_gap_sec)}秒" if pair.max_gap_sec else "なし"
            resp = self._client.models.generate_content(
                model=self._model,
                contents=[
                    f"画像AからBまでの受信間隔は約{elapsed}秒、間の受信の空きは{gap}です。\n\n{PROMPT}",
                    "画像A",
                    t.Part.from_bytes(data=pair.before, mime_type="image/jpeg"),
                    "画像B",
                    t.Part.from_bytes(data=pair.after, mime_type="image/jpeg"),
                ],
                config=config,
            )
            observations = json.loads(resp.text)["observations"]
            if not observations:
                continue
            first = observations[0]
            change, review = (clean(first[k]) for k in ("change", "review"))
            if not change or not review:
                raise ValueError("empty image observation")
            start = pair.start.astimezone(JST)
            end = pair.end.astimezone(JST)
            end_fmt = "%H:%M:%S" if start.date() == end.date() else "%m/%d %H:%M:%S"
            span = f"{start:%m/%d %H:%M:%S}〜{end.strftime(end_fmt)}"
            notes.append(f"{span}（受信・日本時間）\n{change} {review}")
            links.append({"from": pair.from_index, "to": pair.to_index})
        return {"text": "\n\n".join(notes), "model": self._model, "links": links}
