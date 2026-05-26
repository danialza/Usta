use crate::{anthropic::AnthropicProvider, ollama::OllamaProvider, DynProvider};
use std::collections::HashMap;
use std::sync::Arc;

pub struct ProviderRegistry {
    providers: HashMap<String, DynProvider>,
}

impl ProviderRegistry {
    pub fn with_defaults() -> Self {
        let mut map: HashMap<String, DynProvider> = HashMap::new();
        let anth: DynProvider = Arc::new(AnthropicProvider::from_env());
        let oll: DynProvider = Arc::new(OllamaProvider::from_env());
        map.insert(anth.name().into(), anth);
        map.insert(oll.name().into(), oll);
        Self { providers: map }
    }

    pub fn get(&self, name: &str) -> Option<DynProvider> {
        self.providers.get(name).cloned()
    }

    pub fn iter(&self) -> impl Iterator<Item = (&String, &DynProvider)> {
        self.providers.iter()
    }
}
