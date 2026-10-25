"""Turns tool definitions into search results at three detail levels."""
from __future__ import annotations

from typing import Any, Dict, Iterable, List, Tuple

from nitrostack.transforms.search.models import DetailLevel

ALWAYS_VISIBLE_META_KEYS = ("alwaysVisible", "nitrostack/alwaysVisible")


def _props(tool: Any) -> Dict[str, Any]:
    schema = getattr(tool, "inputSchema", None) or {}
    props = schema.get("properties") if isinstance(schema, dict) else None
    return props if isinstance(props, dict) else {}


def _type_label(prop: Any) -> str:
    if not isinstance(prop, dict):
        return "any"
    t = prop.get("type")
    if isinstance(t, list):
        return "|".join(str(x) for x in t)
    if t:
        return str(t)
    any_of = prop.get("anyOf")
    if isinstance(any_of, list):
        return "|".join(str(s.get("type", "any")) for s in any_of if isinstance(s, dict)) or "any"
    return "any"


def param_text(tool: Any) -> str:
    parts: List[str] = []
    for name, prop in _props(tool).items():
        parts.append(str(name))
        if isinstance(prop, dict) and prop.get("description"):
            parts.append(str(prop["description"]))
    return " ".join(parts)


def tool_fields(tool: Any) -> Tuple[str, str, str, str]:
    """(name, title, description, parameter text). Order matches FIELD_WEIGHTS."""
    return (
        getattr(tool, "name", "") or "",
        getattr(tool, "title", None) or "",
        getattr(tool, "description", None) or "",
        param_text(tool),
    )


# A name match outranks a title match, which outranks description, then parameters.
FIELD_WEIGHTS = (4.0, 3.0, 2.0, 1.0)


def first_sentence(text: str, max_len: int = 160) -> str:
    text = (text or "").strip()
    if not text:
        return ""
    head = text.split(". ")[0].strip()
    return head if len(head) <= max_len else head[: max_len - 1].rstrip() + "…"


def is_always_visible(tool: Any, names: Iterable[str]) -> bool:
    # UNVERIFIED: how @tool(metadata=...) lands on the mcp Tool. Check `tool.meta` first.
    if getattr(tool, "name", None) in set(names):
        return True
    meta = getattr(tool, "meta", None)
    if isinstance(meta, dict):
        return any(bool(meta.get(k)) for k in ALWAYS_VISIBLE_META_KEYS)
    return False


def serialize_tool(tool: Any, detail: DetailLevel) -> Dict[str, Any]:
    name = getattr(tool, "name", "")
    description = getattr(tool, "description", None) or ""
    if detail == "brief":
        return {"name": name, "summary": first_sentence(description)}
    if detail == "full":
        return tool.model_dump(by_alias=True, exclude_none=True, mode="json")

    schema = getattr(tool, "inputSchema", None) or {}
    required = set(schema.get("required", [])) if isinstance(schema, dict) else set()
    out: Dict[str, Any] = {"name": name, "description": description}
    title = getattr(tool, "title", None)
    if title:
        out["title"] = title
    out["parameters"] = [
        {
            "name": pname,
            "type": _type_label(prop),
            "required": pname in required,
            "description": prop.get("description", "") if isinstance(prop, dict) else "",
        }
        for pname, prop in _props(tool).items()
    ]
    return out