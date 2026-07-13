# IPC v1

Every frame starts with a big-endian UInt32 body length, then a big-endian UInt32
JSON-header length, the JSON header, and payload bytes. Headers contain `version`,
`requestID`, optional `sessionID`, `kind`, and `messageType`. JSON is used for
control/events and raw little-endian float32 is used for PCM. Frames are capped at
16 MiB. Swift captures 16 kHz mono PCM; TTS responses are 24 kHz mono PCM.
