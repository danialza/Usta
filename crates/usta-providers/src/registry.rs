use crate::{
    anthropic::AnthropicProvider, gemini::GeminiProvider, ollama::OllamaProvider,
    openai::OpenAiProvider, DynProvider,
};
use std::collections::HashMap;
use std::sync::Arc;

pub struct ProviderRegistry {
    providers: HashMap<String, DynProvider>,
}

impl ProviderRegistry {
    pub fn with_defaults() -> Self {
        let mut map: HashMap<String, DynProvider> = HashMap::new();
        let anth: DynProvider = Arc::new(AnthropicProvider::from_env());
        let gem: DynProvider = Arc::new(GeminiProvider::from_env());
        let oll: DynProvider = Arc::new(OllamaProvider::from_env());
        let oai: DynProvider = Arc::new(OpenAiProvider::from_env());
        map.insert(anth.name().into(), anth);
        map.insert(gem.name().into(), gem);
        map.insert(oll.name().into(), oll);
        map.insert(oai.name().into(), oai);
        Self { providers: map }
    }

    pub fn get(&self, name: &str) -> Option<DynProvider> {
        self.providers.get(name).cloned()
    }

    pub fn iter(&self) -> impl Iterator<Item = (&String, &DynProvider)> {
        self.providers.iter()
    }
}
