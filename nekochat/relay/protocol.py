"""The only inbound events are chat.send and ping; extra fields fail closed."""
import json
from pathlib import Path
from typing import Annotated, Literal
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, TypeAdapter

UserID = Annotated[str, StringConstraints(pattern=r"^[a-z0-9][a-z0-9_-]{0,31}$"), Field(json_schema_extra={"not": {"pattern": "[^a-z0-9_-]"}})]
MessageID = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{1,64}$"), Field(json_schema_extra={"not": {"pattern": "[^A-Za-z0-9_-]"}})]
Text = Annotated[str, StringConstraints(min_length=1, max_length=2000, pattern=r"\S")]

class Envelope(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    protocol: Literal["nekochat"]
    version: Literal[1]
    id: MessageID

class Send(Envelope):
    kind: Literal["chat.send"]
    to: UserID
    text: Text

class Ping(Envelope):
    kind: Literal["ping"]

class Ready(Envelope):
    kind: Literal["ready"]
    user: UserID

class Message(Envelope):
    kind: Literal["chat.message"]
    sender: UserID
    text: Text

class Ack(Envelope):
    kind: Literal["chat.ack"]
    status: Literal["delivered", "duplicate"]

class Error(Envelope):
    kind: Literal["error"]
    code: Literal["invalid_event", "forbidden", "offline", "rate_limited"]

class Pong(Envelope):
    kind: Literal["pong"]

ClientEvent = TypeAdapter(Annotated[Send | Ping, Field(discriminator="kind")])
ServerEvent = TypeAdapter(Annotated[Ready | Message | Ack | Error | Pong, Field(discriminator="kind")])

def event(kind: str, event_id: str, **fields) -> dict:
    return ServerEvent.validate_python(dict(protocol="nekochat", version=1, id=event_id, kind=kind, **fields)).model_dump()

if __name__ == "__main__":
    out = Path(__file__).resolve().parents[1] / "protocol"
    for name, adapter in [("client", ClientEvent), ("server", ServerEvent)]:
        schema = adapter.json_schema()
        schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        (out / f"{name}-v1.schema.json").write_text(json.dumps(schema, indent=2) + "\n")
