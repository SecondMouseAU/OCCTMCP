# Components

* [Products and the tool catalogue](products.md) - The two Swift products (OCCTMCPCore library, occtmcp-server executable), the Node implementation beside them, and where the 79-tool catalogue lives.
* [execute_script](execute-script.md) - The data flow behind execute_script, and why writing manifest.json is the side effect that matters.
* [The Node server](node-server.md) - The original Node/TypeScript implementation, file by file: what each module owns, how occtkit is resolved and served, and which tool surface it deliberately does not carry.
* [The Swift server, file by file](swift-server.md) - What each file under Sources/OCCTMCPCore and Sources/OCCTMCPServer owns, one entry per tool family, with the behaviour that is not obvious from the file name.
