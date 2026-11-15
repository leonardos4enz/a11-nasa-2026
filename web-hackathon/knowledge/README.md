# Ember knowledge base

Every `.md` file in this folder (except this README) is indexed for Ember's document search (RAG): split by `##`
sections, embedded with OpenAI `text-embedding-3-small` and stored in the `rag_chunks` table of a11-db. The server
re-indexes on every start and only embeds sections whose text changed, so updating the docs means editing or adding
files here and deploying.

These documents are the team's reference documentation for Ember.
Tips: one topic per file, a `# Title` and `##` sections of a few paragraphs each, plain English.
