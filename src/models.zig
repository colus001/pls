/// Central registry of default models and model choices for each provider.
/// Edit this file to update model defaults across the entire codebase.

// ──────────────────────────────────────────────────────────────────
// Default models (used when no model is configured)
// ──────────────────────────────────────────────────────────────────

pub const DEFAULT_PROXY_MODEL = "gemini-3-flash-preview";
pub const DEFAULT_ANTHROPIC_MODEL = "claude-sonnet-4-6";
pub const DEFAULT_OPENAI_MODEL = "gpt-5.4-mini";
pub const DEFAULT_GEMINI_MODEL = "gemini-3-flash-preview";
pub const DEFAULT_OLLAMA_MODEL = "qwen3:4b";

// ──────────────────────────────────────────────────────────────────
// Model menus (shown in `pls init` and `pls config`)
// ──────────────────────────────────────────────────────────────────

pub const PROXY_MODELS = [_][]const u8{
    "gemini-3-flash-preview",
    "gemini-2.5-flash-lite",
};

pub const ANTHROPIC_MODELS = [_][]const u8{
    "claude-sonnet-4-6",
    "claude-opus-4-6",
    "claude-haiku-4-6",
};

pub const OPENAI_MODELS = [_][]const u8{
    "gpt-5.4-mini",
    "gpt-4.1-mini",
    "gpt-4.1",
};

pub const GEMINI_MODELS = [_][]const u8{
    "gemini-3-flash-preview",
    "gemini-2.5-flash",
    "gemini-2.5-pro",
};

pub const OLLAMA_MODELS = [_][]const u8{
    "qwen3:4b",
    "qwen3:8b",
    "llama3.2",
    "mistral",
};
