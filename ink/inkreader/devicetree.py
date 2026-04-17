from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

__all__ = ["DeviceTreeNode", "DeviceTreeParser", "parse_dts", "load_dts", "dump_dts"]


@dataclass(slots=True)
class DeviceTreeNode:
    name: str
    label: str | None = None
    properties: dict[str, Any] = field(default_factory=dict)
    children: list["DeviceTreeNode"] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "label": self.label,
            "properties": self.properties,
            "children": [child.to_dict() for child in self.children],
        }


@dataclass(slots=True)
class _Token:
    kind: str
    value: str
    pos: int


class DeviceTreeParser:
    def __init__(self, text: str):
        self.tokens = self._tokenize(text)
        self.index = 0

    def parse(self) -> DeviceTreeNode:
        root = DeviceTreeNode(name="/")
        self._parse_block(root, stop_kind="EOF")
        return root

    def _parse_block(self, container: DeviceTreeNode, stop_kind: str) -> None:
        while not self._peek_kind(stop_kind):
            if self._peek_kind("EOF"):
                if stop_kind == "EOF":
                    return
                raise ValueError("unexpected end of input")
            if self._skip_directive():
                continue
            if self._peek_kind("SEMI"):
                self._advance()
                continue

            labels = self._parse_labels()
            if self._looks_like_node():
                if self._is_root_node(container):
                    self._parse_node_into(container, labels)
                else:
                    node = self._parse_node(labels)
                    container.children.append(node)
            else:
                self._parse_property(container)

        if stop_kind != "EOF":
            self._expect(stop_kind)

    def _parse_node(self, labels: list[str]) -> DeviceTreeNode:
        name = self._parse_node_name()
        node = DeviceTreeNode(name=name, label=labels[-1] if labels else None)
        self._expect("LBRACE")
        self._parse_block(node, stop_kind="RBRACE")
        if self._peek_kind("SEMI"):
            self._advance()
        return node

    def _parse_node_into(self, container: DeviceTreeNode, labels: list[str]) -> None:
        self._parse_node_name()
        if labels and container.label is None:
            container.label = labels[-1]
        self._expect("LBRACE")
        self._parse_block(container, stop_kind="RBRACE")
        if self._peek_kind("SEMI"):
            self._advance()

    def _parse_property(self, container: DeviceTreeNode) -> None:
        name = self._expect("WORD").value
        if self._peek_kind("EQUAL"):
            self._advance()
            value = self._parse_value_list()
            self._expect("SEMI")
            container.properties[name] = value
            return
        self._expect("SEMI")
        container.properties[name] = True

    def _parse_value_list(self) -> Any:
        values = [self._parse_value()]
        while self._peek_kind("COMMA"):
            self._advance()
            values.append(self._parse_value())
        return values[0] if len(values) == 1 else values

    def _parse_value(self) -> Any:
        token = self._peek()
        if token.kind == "STRING":
            return self._advance().value
        if token.kind == "NUMBER":
            return int(self._advance().value, 0)
        if token.kind == "AMP":
            self._advance()
            return f"&{self._expect('WORD').value}"
        if token.kind == "WORD":
            return self._advance().value
        if token.kind == "LT":
            return self._parse_angle_list()
        if token.kind == "LBRACKET":
            return self._parse_byte_list()
        raise ValueError(f"unexpected token {token.kind} at {token.pos}")

    def _parse_angle_list(self) -> list[Any]:
        self._expect("LT")
        values: list[Any] = []
        while not self._peek_kind("GT"):
            if self._peek_kind("COMMA"):
                self._advance()
                continue
            if self._peek_kind("AMP"):
                self._advance()
                values.append(f"&{self._expect('WORD').value}")
                continue
            token = self._advance()
            if token.kind == "NUMBER":
                values.append(int(token.value, 0))
            elif token.kind == "WORD":
                values.append(token.value)
            else:
                raise ValueError(f"unexpected token {token.kind} in <...> at {token.pos}")
        self._expect("GT")
        return values

    def _parse_byte_list(self) -> list[int]:
        self._expect("LBRACKET")
        values: list[int] = []
        while not self._peek_kind("RBRACKET"):
            token = self._advance()
            if token.kind == "WORD":
                values.append(int(token.value, 16))
            elif token.kind == "NUMBER":
                values.append(int(token.value, 0))
            elif token.kind == "COMMA":
                continue
            else:
                raise ValueError(f"unexpected token {token.kind} in [..] at {token.pos}")
        self._expect("RBRACKET")
        return values

    def _parse_labels(self) -> list[str]:
        labels: list[str] = []
        while self._peek_kind("WORD") and self._peek_kind("COLON", 1):
            labels.append(self._advance().value)
            self._expect("COLON")
        return labels

    def _parse_node_name(self) -> str:
        token = self._advance()
        if token.kind not in {"WORD", "SLASH"}:
            raise ValueError(f"expected node name at {token.pos}")
        return token.value

    def _looks_like_node(self) -> bool:
        token = self._peek()
        next_token = self._peek(1)
        if token.kind in {"SLASH", "WORD"} and next_token.kind == "LBRACE":
            return True
        if token.kind == "WORD" and next_token.kind == "COLON":
            return True
        return False

    def _is_root_node(self, container: DeviceTreeNode) -> bool:
        token = self._peek()
        return container.name == "/" and token.kind == "WORD" and token.value == "/" and container.label is None

    def _skip_directive(self) -> bool:
        token = self._peek()
        if token.kind != "WORD" or token.value == "/" or not token.value.startswith("/"):
            return False
        self._advance()
        while not self._peek_kind("SEMI") and not self._peek_kind("EOF"):
            self._advance()
        if self._peek_kind("SEMI"):
            self._advance()
        return True

    def _tokenize(self, text: str) -> list[_Token]:
        tokens: list[_Token] = []
        i = 0
        length = len(text)

        while i < length:
            ch = text[i]

            if ch.isspace():
                i += 1
                continue

            if text.startswith("//", i):
                i = text.find("\n", i)
                if i == -1:
                    break
                continue

            if text.startswith("/*", i):
                end = text.find("*/", i + 2)
                if end == -1:
                    raise ValueError("unterminated block comment")
                i = end + 2
                continue

            if ch == '"':
                start = i
                i += 1
                value = []
                while i < length:
                    current = text[i]
                    if current == '\\':
                        if i + 1 >= length:
                            raise ValueError("unterminated string escape")
                        escape = text[i + 1]
                        mapping = {"n": "\n", "r": "\r", "t": "\t", '"': '"', "\\": "\\"}
                        value.append(mapping.get(escape, escape))
                        i += 2
                        continue
                    if current == '"':
                        i += 1
                        break
                    value.append(current)
                    i += 1
                else:
                    raise ValueError("unterminated string literal")
                tokens.append(_Token("STRING", "".join(value), start))
                continue

            if ch in "{};:=<>,[]":
                kind = {
                    "{": "LBRACE",
                    "}": "RBRACE",
                    ";": "SEMI",
                    ":": "COLON",
                    "=": "EQUAL",
                    "<": "LT",
                    ">": "GT",
                    ",": "COMMA",
                    "[": "LBRACKET",
                    "]": "RBRACKET",
                }[ch]
                tokens.append(_Token(kind, ch, i))
                i += 1
                continue

            if ch == "&":
                tokens.append(_Token("AMP", ch, i))
                i += 1
                continue

            start = i
            while i < length:
                current = text[i]
                if current.isspace() or current in "{};:=<>,[]\"&":
                    break
                if text.startswith("//", i) or text.startswith("/*", i):
                    break
                i += 1
            raw = text[start:i]
            if raw.startswith(("0x", "0X")) or raw.isdigit() or (raw.startswith(("-", "+")) and raw[1:].isdigit()):
                tokens.append(_Token("NUMBER", raw, start))
            else:
                tokens.append(_Token("WORD", raw, start))

        tokens.append(_Token("EOF", "", length))
        return tokens

    def _peek(self, offset: int = 0) -> _Token:
        index = min(self.index + offset, len(self.tokens) - 1)
        return self.tokens[index]

    def _peek_kind(self, kind: str, offset: int = 0) -> bool:
        return self._peek(offset).kind == kind

    def _advance(self) -> _Token:
        token = self.tokens[self.index]
        self.index += 1
        return token

    def _expect(self, kind: str) -> _Token:
        token = self._advance()
        if token.kind != kind:
            raise ValueError(f"expected {kind} at {token.pos}, got {token.kind}")
        return token


def parse_dts(text: str) -> dict[str, Any]:
    return DeviceTreeParser(text).parse().to_dict()


def load_dts(path: str | Path) -> dict[str, Any]:
    return parse_dts(Path(path).read_text(encoding="utf-8"))


def dump_dts(data: dict[str, Any]) -> str:
    return json.dumps(data, indent=2, sort_keys=True)
