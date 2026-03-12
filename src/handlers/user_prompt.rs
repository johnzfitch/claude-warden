use std::sync::Arc;

use crate::server::AppState;
use crate::types::{HookInput, HookOutput};

pub fn handle(_state: &Arc<AppState>, _input: &HookInput) -> HookOutput {
    // Passthrough for now — future: prompt validation, budget checks
    HookOutput::passthrough()
}
