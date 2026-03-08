# Graph RAG & Knowledge Graphs

[Back to Index](README.md)

---

## Overview

Knowledge graphs represent information as a network of entities and relationships, enabling reasoning that flat document retrieval cannot achieve. While standard RAG excels at finding relevant text passages, it struggles with questions that require connecting multiple entities across documents — for example, "Which servicers have historical delinquency rates above 5% on pools issued by Countrywide before 2008?" Graph RAG combines graph traversal with vector search to answer complex multi-hop questions.

For data engineers in the secondary mortgage market, knowledge graphs unlock entity-centric views of MBS deal structures: issuer → deal → tranche → loan → borrower → property, plus counterparty relationships, servicer histories, and regulatory entity hierarchies.

---

## Key Concepts at a Glance

| Concept | Definition |
|---|---|
| Knowledge Graph (KG) | Network of (entity, relationship, entity) triples |
| Triple | `(subject, predicate, object)` — e.g., `(Deal_ABC_2024, hasServicer, WellsFargo)` |
| Node | An entity: a deal, a tranche, a loan, a borrower |
| Edge | A typed relationship between two entities |
| Graph traversal | Following edges to discover connected entities (BFS/DFS) |
| Community detection | Grouping densely connected nodes (e.g., Louvain algorithm) |
| GraphRAG | Microsoft's technique: use graph structure + summaries to augment RAG retrieval |
| Multi-hop | Reasoning requiring 2+ edge traversals to answer a question |

---

## 1. What is a Knowledge Graph?

A knowledge graph stores facts as triples:

```
(WellsFargoBank, isServicerFor, WFMBS_2024_1)
(WFMBS_2024_1, hasTranche, WFMBS_2024_1_A1)
(WFMBS_2024_1_A1, hasRating, AAA)
(WFMBS_2024_1, collateralType, PrimeJumbo)
(JohnSmith, hasMortgage, LN_20240001)
(LN_20240001, isContainedIn, WFMBS_2024_1)
```

This structure supports queries that join multiple facts that may live in separate documents:
- "What rating does the A1 tranche of the Well Fargo 2024-1 deal have?"
- "Which deals contain loans originated by Chase?"
- "What properties are collateral for loans in deals rated below BBB?"

---

## 2. Graph Databases

### Neo4j (Property Graph Model)

The most widely used graph database. Uses the Cypher query language. Native graph storage with pointer-based adjacency — traversals do not require JOINs.

```cypher
-- Create MBS deal structure
CREATE (issuer:Institution {name: "Wells Fargo", type: "Bank", bloomberg_id: "WFC US"})
CREATE (deal:Deal {id: "WFMBS-2024-1", type: "RMBS", origination_year: 2024,
                   total_balance: 500000000})
CREATE (trancheA:Tranche {id: "WFMBS-2024-1-A1", class: "A1", rating: "AAA",
                          balance: 400000000, coupon: 0.065})
CREATE (trancheB:Tranche {id: "WFMBS-2024-1-B1", class: "B1", rating: "BBB",
                          balance: 50000000, coupon: 0.085})
CREATE (servicer:Institution {name: "Wells Fargo Servicing", type: "Servicer"})

-- Relationships
CREATE (issuer)-[:ISSUED]->(deal)
CREATE (deal)-[:HAS_TRANCHE]->(trancheA)
CREATE (deal)-[:HAS_TRANCHE]->(trancheB)
CREATE (servicer)-[:SERVICES]->(deal)

-- Query: find all deals with a AAA tranche serviced by Wells Fargo
MATCH (s:Institution {type: "Servicer"})-[:SERVICES]->(d:Deal)-[:HAS_TRANCHE]->(t:Tranche)
WHERE s.name CONTAINS "Wells Fargo"
  AND t.rating = "AAA"
RETURN d.id, d.total_balance, t.class, t.balance
ORDER BY d.total_balance DESC
```

### Amazon Neptune

Managed graph database supporting both Property Graph (Gremlin) and RDF (SPARQL). Good for AWS-native architectures.

```python
# Gremlin traversal with gremlinpython
from gremlin_python.driver.driver_remote_connection import DriverRemoteConnection
from gremlin_python.process.anonymous_traversal import traversal

g = traversal().withRemote(
    DriverRemoteConnection("wss://<neptune-endpoint>:8182/gremlin", "g")
)

# Find all tranches of deals issued after 2020 with balance > 100M
results = (
    g.V()
    .hasLabel("Deal")
    .has("origination_year", P.gte(2020))
    .where(__.has("total_balance", P.gte(100_000_000)))
    .out("HAS_TRANCHE")
    .valueMap("id", "rating", "balance")
    .toList()
)
```

---

## 3. SQL Server Graph Tables

SQL Server 2017+ supports graph tables natively using NODE and EDGE tables with a Cypher-like MATCH syntax. This is particularly relevant given your SQL Server background.

```sql
-- Create NODE tables
CREATE TABLE dbo.Institution (
    name        NVARCHAR(200) NOT NULL,
    inst_type   NVARCHAR(50)  NOT NULL,   -- Issuer, Servicer, Trustee, Insurer
    bloomberg_id NVARCHAR(20),
    CONSTRAINT PK_Institution PRIMARY KEY (name)
) AS NODE;

CREATE TABLE dbo.Deal (
    deal_id            NVARCHAR(50) NOT NULL,
    deal_type          NVARCHAR(30),       -- RMBS, CMBS, CLO, ABS
    origination_year   SMALLINT,
    total_balance      DECIMAL(18,2),
    cusip              CHAR(9),
    CONSTRAINT PK_Deal PRIMARY KEY (deal_id)
) AS NODE;

CREATE TABLE dbo.Tranche (
    tranche_id  NVARCHAR(50) NOT NULL,
    class_name  NVARCHAR(10),
    rating      NVARCHAR(10),
    balance     DECIMAL(18,2),
    coupon      DECIMAL(8,6),
    CONSTRAINT PK_Tranche PRIMARY KEY (tranche_id)
) AS NODE;

-- Create EDGE tables
CREATE TABLE dbo.Issued      (issue_date DATE)  AS EDGE;
CREATE TABLE dbo.HasTranche  ()                 AS EDGE;
CREATE TABLE dbo.Services    (start_date DATE)  AS EDGE;

-- Insert nodes
INSERT INTO dbo.Institution (name, inst_type) VALUES ('Wells Fargo Bank', 'Issuer');
INSERT INTO dbo.Deal (deal_id, deal_type, origination_year, total_balance)
    VALUES ('WFMBS-2024-1', 'RMBS', 2024, 500000000);
INSERT INTO dbo.Tranche (tranche_id, class_name, rating, balance)
    VALUES ('WFMBS-2024-1-A1', 'A1', 'AAA', 400000000);

-- Insert edges (using $node_id)
INSERT INTO dbo.Issued ($from_id, $to_id, issue_date)
SELECT i.$node_id, d.$node_id, '2024-03-15'
FROM dbo.Institution i, dbo.Deal d
WHERE i.name = 'Wells Fargo Bank' AND d.deal_id = 'WFMBS-2024-1';

INSERT INTO dbo.HasTranche ($from_id, $to_id)
SELECT d.$node_id, t.$node_id
FROM dbo.Deal d, dbo.Tranche t
WHERE d.deal_id = 'WFMBS-2024-1' AND t.tranche_id = 'WFMBS-2024-1-A1';

-- MATCH query: find all deals and their tranches issued by Wells Fargo
SELECT
    i.name          AS issuer,
    d.deal_id,
    d.origination_year,
    t.class_name,
    t.rating,
    t.balance
FROM dbo.Institution i,
     dbo.Issued      issuedge,
     dbo.Deal        d,
     dbo.HasTranche  htedge,
     dbo.Tranche     t
WHERE MATCH(i-(issuedge)->d-(htedge)->t)
  AND i.inst_type = 'Issuer'
ORDER BY d.deal_id, t.class_name;
```

---

## 4. Building a Knowledge Graph from Documents with LLMs

The most powerful way to build a KG from unstructured mortgage documents is LLM-based entity and relationship extraction.

```python
import json
from anthropic import Anthropic
import neo4j

client = Anthropic()

EXTRACTION_PROMPT = """Extract entities and relationships from this mortgage document excerpt.

Return a JSON object with two keys:
- "entities": list of {{"id": str, "type": str, "properties": dict}}
- "relationships": list of {{"from_id": str, "type": str, "to_id": str, "properties": dict}}

Entity types: Deal, Tranche, Institution, Loan, Borrower, Property, GuidelineRule, RegulatoryBody
Relationship types: HAS_TRANCHE, ISSUED_BY, SERVICED_BY, CONTAINS_LOAN, COLLATERALIZED_BY,
                    ORIGINATED_BY, GOVERNED_BY, REFERENCES_RULE, COUNTERPARTY_TO

Document excerpt:
{text}

JSON output:"""


def extract_kg_from_text(text: str) -> dict:
    response = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=2000,
        messages=[{
            "role": "user",
            "content": EXTRACTION_PROMPT.format(text=text)
        }]
    )
    raw = response.content[0].text
    # Strip markdown code fences if present
    raw = raw.strip().removeprefix("```json").removeprefix("```").removesuffix("```")
    return json.loads(raw.strip())


def load_kg_to_neo4j(kg_data: dict, driver: neo4j.Driver) -> None:
    with driver.session() as session:
        # Upsert entities
        for entity in kg_data.get("entities", []):
            props = {k: v for k, v in entity["properties"].items() if v is not None}
            props["id"] = entity["id"]
            session.run(
                f"MERGE (n:{entity['type']} {{id: $id}}) SET n += $props",
                id=entity["id"],
                props=props,
            )

        # Upsert relationships
        for rel in kg_data.get("relationships", []):
            rel_props = rel.get("properties", {})
            session.run(
                f"""
                MATCH (a {{id: $from_id}}), (b {{id: $to_id}})
                MERGE (a)-[r:{rel['type']}]->(b)
                SET r += $props
                """,
                from_id=rel["from_id"],
                to_id=rel["to_id"],
                props=rel_props,
            )


# Example usage
driver = neo4j.GraphDatabase.driver("bolt://localhost:7687", auth=("neo4j", "password"))

text = """
The WFMBS 2024-1 trust was issued by Wells Fargo Bank, N.A. on March 15, 2024.
The deal contains 1,247 prime jumbo mortgage loans with an aggregate balance of $500 million.
Wells Fargo Mortgage Servicing will act as the master servicer.
The Class A1 certificates, rated AAA by Moody's, have a balance of $400 million.
The collateral consists of first-lien, fully amortizing 30-year fixed-rate loans.
"""

kg = extract_kg_from_text(text)
load_kg_to_neo4j(kg, driver)
print(f"Extracted {len(kg['entities'])} entities, {len(kg['relationships'])} relationships")
```

---

## 5. Microsoft GraphRAG

Microsoft's GraphRAG extends standard RAG with graph-based retrieval by:

1. **Entity extraction:** Run LLM over the corpus to extract all entities and relationships.
2. **Community detection:** Group related entities into communities (Louvain algorithm on the entity graph).
3. **Hierarchical summarization:** Generate summaries at multiple levels — entity level, community level, global level.
4. **Two retrieval modes:**
   - **Local search:** Start from seed entities mentioned in the query, traverse the graph to gather context.
   - **Global search:** Use community summaries to answer broad, thematic queries ("What are the main risk factors in this portfolio?").

```python
# Using the graphrag Python package (Microsoft open source)
import asyncio
from graphrag.query.context_builder.local_context import LocalSearchMixedContext
from graphrag.query.llm.oai.chat_openai import ChatOpenAI
from graphrag.query.structured_search.local_search.search import LocalSearch

async def graph_rag_query(question: str) -> str:
    # Load pre-built GraphRAG index
    # (built via: python -m graphrag.index --root ./mortgage_kg)

    llm = ChatOpenAI(api_key="<key>", model="gpt-4o")
    context_builder = LocalSearchMixedContext(
        community_reports=community_reports,   # pre-loaded from GraphRAG index
        text_units=text_units,
        entities=entities,
        relationships=relationships,
        entity_text_embeddings=entity_embeddings,
        embedding_vectorstore_key="id",
        text_embedder=embedder,
    )
    search_engine = LocalSearch(
        llm=llm,
        context_builder=context_builder,
        token_encoder=tiktoken.get_encoding("cl100k_base"),
        llm_params={"max_tokens": 2000, "temperature": 0.0},
    )
    result = await search_engine.asearch(question)
    return result.response

# Global search for broad questions
# python -m graphrag.query --root ./mortgage_kg --method global
# "What are the main counterparty concentration risks in this MBS portfolio?"
```

---

## 6. Graph RAG: Combining Graph Traversal + Vector Search

The core pattern for Graph RAG in mortgage data:

```python
from neo4j import GraphDatabase
from sentence_transformers import SentenceTransformer
import faiss
import numpy as np

embedder = SentenceTransformer("sentence-transformers/all-mpnet-base-v2")
driver = GraphDatabase.driver("bolt://localhost:7687", auth=("neo4j", "password"))

def graph_rag_retrieve(query: str, seed_entity_id: str = None, hops: int = 2) -> dict:
    """
    Two-phase retrieval:
    1. Graph traversal: collect entity context within N hops of seed entity
    2. Vector search: find semantically similar text chunks
    Merge results for richer context assembly.
    """
    graph_context = []
    vector_context = []

    # Phase 1: Graph traversal
    if seed_entity_id:
        with driver.session() as session:
            result = session.run(
                """
                MATCH path = (start {id: $seed_id})-[*1..""" + str(hops) + """]->(neighbor)
                RETURN
                    [n IN nodes(path) | n.id + ' (' + labels(n)[0] + ')'] AS node_chain,
                    [r IN relationships(path) | type(r)] AS rel_chain,
                    neighbor.id AS neighbor_id,
                    labels(neighbor)[0] AS neighbor_type,
                    properties(neighbor) AS neighbor_props
                LIMIT 50
                """,
                seed_id=seed_entity_id
            )
            for record in result:
                graph_context.append({
                    "path": " -> ".join(
                        f"{n} -[{r}]->"
                        for n, r in zip(record["node_chain"], record["rel_chain"])
                    ) + f" {record['neighbor_id']}",
                    "entity": record["neighbor_id"],
                    "type": record["neighbor_type"],
                    "properties": record["neighbor_props"],
                })

    # Phase 2: Vector search (standard RAG retrieval)
    q_emb = embedder.encode([query], normalize_embeddings=True).astype(np.float32)
    distances, indices = faiss_index.search(q_emb, k=5)
    for dist, idx in zip(distances[0], indices[0]):
        vector_context.append({
            "chunk_text": corpus[idx],
            "similarity": float(dist),
        })

    return {
        "graph_context": graph_context,
        "vector_context": vector_context,
    }


def assemble_graph_rag_prompt(query: str, context: dict) -> str:
    graph_section = "\n".join(
        f"- {c['path']} | Properties: {c['properties']}"
        for c in context["graph_context"][:20]
    )
    vector_section = "\n\n".join(
        c["chunk_text"] for c in context["vector_context"]
    )

    return f"""You are an MBS deal analyst. Use the graph relationships and document excerpts
below to answer the question.

GRAPH RELATIONSHIPS:
{graph_section}

DOCUMENT EXCERPTS:
{vector_section}

QUESTION: {query}

ANSWER:"""
```

---

## 7. MBS Deal Entity Graph Schema

A canonical knowledge graph schema for secondary mortgage market data:

```
Nodes:
  Institution  (id, name, type: Issuer|Servicer|Trustee|Insurer|Custodian|RatingAgency)
  Deal         (id, cusip, deal_type, origination_date, total_balance, collateral_type)
  Tranche      (id, class, rating, balance, coupon, payment_priority, cusip)
  Loan         (id, original_balance, ltv, fico, property_state, loan_purpose)
  Property     (id, address, appraisal_value, property_type, state, zip)
  Borrower     (id, fico_at_origination, dti, employment_type)  -- anonymized
  GuidelineDoc (id, issuer, version, effective_date, doc_type)
  RegBody      (id, name, jurisdiction)  -- CFPB, FHFA, OCC, etc.

Edges:
  Institution  -[ISSUED]->        Deal
  Institution  -[SERVICES]->      Deal
  Institution  -[IS_TRUSTEE_FOR]->Deal
  Institution  -[RATED_BY]->      Tranche  {rating, rating_date}
  Deal         -[HAS_TRANCHE]->   Tranche
  Deal         -[CONTAINS_LOAN]-> Loan     {pool_cut_date}
  Loan         -[COLLATERALIZED_BY]->Property
  Loan         -[ORIGINATED_BY]-> Institution
  Borrower     -[TOOK_OUT]->      Loan
  Tranche      -[SUBORDINATE_TO]->Tranche  -- payment waterfall
  Deal         -[GOVERNED_BY]->   GuidelineDoc
  RegBody      -[REGULATES]->     Institution
  Institution  -[COUNTERPARTY_TO]->Institution {relationship_type}
```

---

## 8. Cypher vs. Gremlin vs. SPARQL

| Dimension | Cypher (Neo4j) | Gremlin (TinkerPop) | SPARQL (RDF) |
|---|---|---|---|
| Style | Declarative, ASCII-art patterns | Imperative, traversal steps | Declarative, triple patterns |
| Readability | High | Medium | Low |
| Use case | Property graphs, Neo4j | Multi-platform (Neptune, JanusGraph) | Semantic web, OWL ontologies |
| Pattern matching | Excellent | Good | Excellent |
| Learning curve | Low | Medium | High |
| SQL Server graph | Not supported | Not supported | Not supported |
| SQL Server MATCH | Closest to Cypher | N/A | N/A |

```cypher
-- Cypher: 2-hop traversal
MATCH (i:Institution {name: "Chase"})-[:ISSUED]->(d:Deal)-[:HAS_TRANCHE]->(t:Tranche)
WHERE t.rating IN ["AAA", "AA+"]
RETURN i.name, d.deal_id, t.class_name, t.balance

-- Equivalent Gremlin
g.V().hasLabel("Institution").has("name", "Chase")
 .out("ISSUED")
 .as("deal")
 .out("HAS_TRANCHE")
 .has("rating", P.within("AAA", "AA+"))
 .project("deal_id", "class_name", "balance")
 .by(__.select("deal").values("deal_id"))
 .by(values("class_name"))
 .by(values("balance"))

-- Equivalent SPARQL
SELECT ?dealId ?className ?balance
WHERE {
  ?inst  rdf:type      :Institution ;
         :name         "Chase" .
  ?deal  :issuedBy     ?inst ;
         :id           ?dealId .
  ?tranche :belongsTo  ?deal ;
           :className  ?className ;
           :rating      ?rating ;
           :balance     ?balance .
  FILTER(?rating IN ("AAA", "AA+"))
}
```

---

## 9. Community Detection for GraphRAG Summarization

```python
import networkx as nx
import community as community_louvain  # python-louvain package

def build_networkx_graph(neo4j_driver) -> nx.Graph:
    G = nx.Graph()
    with neo4j_driver.session() as session:
        # Load all edges
        result = session.run("""
            MATCH (a)-[r]->(b)
            RETURN a.id AS source, type(r) AS rel_type, b.id AS target,
                   labels(a)[0] AS source_type, labels(b)[0] AS target_type
            LIMIT 100000
        """)
        for record in result:
            G.add_node(record["source"], entity_type=record["source_type"])
            G.add_node(record["target"], entity_type=record["target_type"])
            G.add_edge(record["source"], record["target"],
                       rel_type=record["rel_type"])
    return G


def detect_communities(G: nx.Graph) -> dict:
    """Returns {node_id: community_id} mapping."""
    partition = community_louvain.best_partition(G)
    n_communities = len(set(partition.values()))
    print(f"Detected {n_communities} communities in graph of {G.number_of_nodes()} nodes")
    return partition


def summarize_community(community_nodes: list[str], llm_client) -> str:
    """Generate a natural-language summary of a community for global search."""
    node_list = "\n".join(f"- {n}" for n in community_nodes[:50])
    response = llm_client.messages.create(
        model="claude-3-5-haiku-20241022",
        max_tokens=500,
        messages=[{
            "role": "user",
            "content": (
                f"Summarize the key characteristics and relationships of this group "
                f"of entities from a mortgage securitization knowledge graph:\n\n"
                f"{node_list}\n\n"
                f"Provide a concise 2-3 sentence summary identifying what these "
                f"entities have in common and their significance."
            )
        }]
    )
    return response.content[0].text
```

---

## Interview Q&A

**Q1. What is a knowledge graph and how does it differ from a relational database?**

A knowledge graph represents information as a network of typed entities connected by typed relationships, stored as triples `(subject, predicate, object)`. A relational database stores data in fixed-schema tables; joining across tables is expensive and requires predefined foreign key relationships. A knowledge graph is schema-flexible — new entity types and relationship types can be added without altering existing structure. More importantly, traversal queries (find all entities within 3 hops of this deal) are native operations with O(log N) complexity in a native graph store, versus exponentially expensive multi-way JOINs in SQL. For MBS deal analysis, a KG naturally models the hierarchical deal structure plus cross-cutting counterparty relationships without requiring 10-way JOINs.

**Q2. Explain SQL Server graph tables. How do NODE and EDGE tables differ from regular tables, and what can MATCH do that JOIN cannot?**

NODE and EDGE tables are standard SQL Server tables with hidden system columns: `$node_id` (a JSON path identifier for the node), `$from_id` (source node for edges), and `$to_id` (target node for edges). You create them by appending `AS NODE` or `AS EDGE` to a `CREATE TABLE` statement. The `MATCH` clause in a `SELECT` statement expresses graph traversal patterns using the syntax `(node1)-(edge)->(node2)`, similar to Cypher. What `MATCH` enables that `JOIN` cannot do cleanly is variable-length path traversal — finding all entities reachable within 1-3 hops without writing a recursive CTE or a fixed number of JOINs. `MATCH` also makes the traversal intent clear and executable with better query plan optimization for graph patterns.

**Q3. What is GraphRAG and how does it improve over standard vector RAG for complex queries?**

Standard vector RAG retrieves semantically similar text chunks but cannot reason about entity relationships across documents. GraphRAG (Microsoft's approach) first builds a knowledge graph from the corpus by extracting entities and relationships using an LLM. It then runs community detection to identify groups of closely related entities and generates hierarchical summaries — entity summaries, community summaries, and global thematic summaries. At query time, a local search traverses the entity graph from seed entities mentioned in the query to gather structured relationship context. A global search uses community summaries to answer thematic questions ("What are the systemic risk patterns in this portfolio?") that standard RAG would need to synthesize from dozens of fragmented chunks. The key improvement is multi-hop reasoning: GraphRAG can connect Deal → Servicer → Historical Performance → Risk Pattern across facts that appear in entirely separate documents.

**Q4. How would you build a knowledge graph from a corpus of MBS prospectuses stored in Snowflake?**

(1) **Extract text:** Run a Snowflake Task that calls `SNOWFLAKE.CORTEX.PARSE_DOCUMENT` on staged PDFs to extract clean text, storing results in a `prospectus_text` table. (2) **Chunk and extract:** For each chunk, call `SNOWFLAKE.CORTEX.COMPLETE` with an entity/relationship extraction prompt that outputs structured JSON. Store extracted triples in `kg_entities` and `kg_relationships` tables. (3) **Deduplicate entities:** Use string similarity (`JAROWINKLER_SIMILARITY`) and LLM-based disambiguation to merge "Wells Fargo Bank, N.A." and "WFB" into a single entity node. (4) **Load to graph DB:** Sync the Snowflake KG tables to Neo4j using the `neo4j-connector-snowflake` or a scheduled Python job. (5) **Embed entities:** Generate entity description embeddings for vector search over entity properties alongside graph traversal.

**Q5. Compare Cypher, Gremlin, and SPARQL. Which would you use for an MBS counterparty network?**

For an MBS counterparty network, I'd choose Cypher/Neo4j. Cypher's declarative pattern syntax reads naturally for relationship queries — `MATCH (a:Institution)-[:COUNTERPARTY_TO]->(b:Institution)` is immediately readable by anyone familiar with graph concepts. Gremlin is more powerful for complex, programmatic traversals but its imperative style makes simple relationship queries verbose. SPARQL is designed for RDF/semantic web use cases and OWL ontologies; it brings significant overhead for what is fundamentally a property graph problem. If the architecture requires AWS Neptune (for managed infrastructure and IAM integration), I'd use Gremlin via the Neptune Gremlin endpoint. SPARQL would only make sense if regulatory ontologies (like FIBO — the Financial Industry Business Ontology) are incorporated.

**Q6. What are the data quality challenges in LLM-based entity extraction from mortgage documents, and how do you address them?**

**Challenges:** (1) Entity disambiguation — "WFB", "Wells Fargo Bank, N.A.", and "Wells Fargo Mortgage" may be the same or different entities. (2) Relationship hallucination — the LLM may infer relationships not explicitly stated. (3) Inconsistent entity IDs across documents. (4) Missing context — a chunk referencing "the issuer" without naming it requires cross-chunk resolution. (5) Numeric precision — deal balances extracted as "$500M" vs. "$500,000,000" need normalization.

**Mitigations:** Use a constrained output schema (JSON with enum types for entity and relationship types). Extract with high temperature and then deduplicate/validate in a separate step. Build a canonical entity registry table in Snowflake and resolve extracted entities against it using LEVENSHTEIN distance + LLM-based confirmation. Flag low-confidence extractions for human review. Validate numeric values against structured data sources (Bloomberg, Intex) as a cross-check.

**Q7. How does community detection improve the quality of global search queries in GraphRAG?**

Global queries like "What are the main counterparty concentration risks in the 2023 vintage of private label deals?" cannot be answered by retrieving individual text chunks — the answer requires synthesizing patterns across the entire corpus. Community detection (Louvain, Leiden) groups entities that are densely interconnected — for example, a cluster of deals all issued by the same institution and serviced by the same servicer. Pre-generated community summaries describe what each cluster has in common. When a global query arrives, the system can directly query these summaries rather than trying to synthesize thousands of chunks. The hierarchical structure (entity → community → super-community) allows the model to answer at the appropriate level of abstraction.

**Q8. You need to answer the question: "Which servicers have delinquency rates above 5% on loans in AAA-rated tranches?" How would Graph RAG handle this vs. standard RAG?**

**Standard RAG** would retrieve chunks containing "delinquency" and "AAA" but would likely return fragmented information from individual deal reports, unable to aggregate across deals or traverse the servicer → deal → tranche → performance hierarchy.

**Graph RAG** approach: (1) Identify seed entities from the query: `Tranche (rating=AAA)` and `delinquency_rate`. (2) Graph traversal: `Tranche(AAA) <- HAS_TRANCHE - Deal - SERVICED_BY -> Institution(Servicer)`. (3) Augment with vector retrieval of performance report chunks mentioning delinquency for those specific deals. (4) Assemble context that includes both structured graph facts (which servicer services which AAA deal) and text chunks with the actual delinquency numbers. The graph traversal provides the structural join that standard RAG cannot do; vector search provides the numerical detail.

**Q9. How would you model the Fannie Mae/Freddie Mac guideline hierarchy in a knowledge graph to enable precise RAG retrieval?**

Model guideline sections as nodes:

```cypher
(:GuidelineDoc {id: "FNM-SEL-2024", name: "Fannie Mae Selling Guide 2024"})
  -[:HAS_CHAPTER]->
(:Chapter {id: "B3", title: "Underwriting Borrowers"})
  -[:HAS_SECTION]->
(:Section {id: "B3-4.3", title: "Assets"})
  -[:HAS_SUBSECTION]->
(:Subsection {id: "B3-4.3-04", title: "Personal Gifts", text: "..."})
```

Each subsection node stores the full text plus an embedding. Cross-references between sections become edges: `(B3-4.3-04)-[:CROSS_REFERENCES]->(B3-2.1-01)`. This enables: (1) Exact section retrieval by ID. (2) Semantic search over subsection text using vector similarity on node embeddings. (3) Graph traversal to collect related sections (cross-references, parent sections) when a single subsection is retrieved — automatically pulling in context the analyst needs.

**Q10. What are the production infrastructure considerations for a knowledge graph supporting 50 million mortgage loans?**

At this scale, a single Neo4j instance becomes a bottleneck. Considerations: (1) **Separate hot vs. cold graph.** Keep the deal/tranche/servicer structure (thousands of nodes) in a fully in-memory Neo4j instance. The 50M loan nodes should stay in Snowflake as a fact table; query them via Snowflake and join to the graph layer. Don't try to load 50M nodes into Neo4j. (2) **Graph partitioning by vintage or deal.** Query pattern analysis likely shows most traversals stay within a single deal's subgraph. Partition accordingly. (3) **Read replicas.** Neo4j Enterprise supports causal clustering with read replicas for query load distribution. (4) **Embedding sync.** Entity embeddings in the graph need to be consistent with the FAISS/Snowflake vector index. Treat the graph DB as the system of record; sync embeddings as an export. (5) **Change data capture.** Loan-level attributes (current balance, delinquency status) change monthly. Use a CDC pipeline from the servicing data warehouse to update graph node properties without full reloads.

---

## Pro Tips

- **Start with a property graph, not RDF.** For mortgage data engineering, the property graph model (Neo4j, SQL Server graph) is simpler to build and maintain than RDF triples. Adopt RDF only if you need to integrate with financial ontologies like FIBO.
- **SQL Server graph is underused.** If your architecture already uses SQL Server, graph tables add near-zero operational overhead. They are excellent for modeling the deal/tranche/loan hierarchy without new infrastructure.
- **Entity deduplication is the hardest problem.** Invest in a canonical entity registry before building the KG. A borrower record appearing in 3 different servicer systems as "J. Smith", "John Smith", and "SMITH, JOHN R" must resolve to one node or your graph produces misleading traversal results.
- **Keep text chunks linked to graph nodes.** Store `chunk_id` references on graph nodes so that a graph traversal can immediately retrieve the source text passages. This is the core integration point for Graph RAG.
- **Graph traversal depth matters for latency.** Every additional hop multiplies the number of nodes examined. In production, limit traversal depth to 2-3 hops and add entity type filters on each step. Index frequently traversed relationship types.
- **Community summaries are cheap to generate but expensive to regenerate.** Run community detection and summary generation as a scheduled batch job (weekly or after major corpus updates), not at query time.
- **For Cypher beginners:** The visual pattern `(a)-[:REL]->(b)` maps directly to how you would draw the relationship on a whiteboard. The arrow direction matters. Use `EXPLAIN` in Neo4j Browser to inspect query plans and add indexes on frequently filtered properties.
- **Intex CDI data is naturally graph-structured.** Intex deal objects (deals, tranches, bonds, collateral groups) map directly to graph nodes. Consider building a KG layer on top of your Intex data extract to enable multi-deal analysis queries that Intex's own UI cannot perform.
