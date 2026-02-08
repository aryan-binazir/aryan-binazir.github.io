---
title: "Practical RAG: Lessons From Putting Retrieval-Augmented Generation in Production"
date: 2025-02-01
tag: AI / ML
excerpt: RAG sounds simple in a demo. In production it's a pipeline of tradeoffs around chunking, embedding models, retrieval strategies, and prompt design.
---

Everyone's building RAG pipelines right now, and most of the tutorials make it look trivial: embed your documents, throw them in a vector store, retrieve the top-k chunks, stuff them into a prompt. Ship it. In practice, every one of those steps hides a set of decisions that will make or break your system's usefulness.

## Chunking Is the Whole Game

Your retrieval quality is bounded by your chunking strategy. Split too aggressively and you lose context. Split too conservatively and you dilute relevance. I've found that recursive character splitting with overlap works for most document types, but structured data (tables, code, configs) almost always needs custom logic.

## Embedding Model Selection

Not all embeddings are created equal. For domain-specific use cases, a fine-tuned embedding model consistently outperforms general-purpose ones. The MTEB leaderboard is a good starting point, but benchmark performance doesn't always translate to your specific retrieval task. Test with your actual data.

## Retrieval Strategy

Pure vector similarity search gets you 70% of the way there. The remaining 30% comes from hybrid approaches:

- **Hybrid search:** Combine dense vector search with sparse keyword matching (BM25). Catches cases where exact terminology matters.
- **Reranking:** Use a cross-encoder to rerank your initial retrieval results. Adds latency but significantly improves precision.
- **Metadata filtering:** Filter by document type, date, or source before vector search. Reduces noise dramatically.

## Prompt Engineering for RAG

The prompt template matters more than you'd think. Explicitly telling the model to only use the provided context, to cite sources, and to say "I don't know" when the context doesn't support an answer — these aren't nice-to-haves, they're requirements for a system that users can trust.

```
# Basic RAG prompt structure
You are a helpful assistant. Answer the question using ONLY
the context provided below. If the context doesn't contain
enough information to answer, say "I don't have enough
information to answer that."

Context:
{retrieved_chunks}

Question: {user_query}
```

## Evaluating RAG Systems

You need three metrics at minimum: retrieval precision (are you fetching relevant chunks?), answer faithfulness (is the answer grounded in the retrieved context?), and answer relevance (does the answer actually address the question?). Build an eval set early and run it on every change to your pipeline.
