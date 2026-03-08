# TensorFlow & PyTorch for Data Engineers

[Back to Index](README.md)

---

## Overview

PyTorch and TensorFlow are the two dominant deep learning frameworks. For a senior data engineer in the secondary mortgage market, you are unlikely to train ResNets from scratch — but you will encounter these frameworks when: integrating trained models into SQL Server or Snowflake pipelines via ONNX, building LSTM-based time-series forecasting for loan performance, deploying models via TorchServe or TF Serving, or loading pre-trained HuggingFace models (which are PyTorch or TF underneath).

This guide covers the essential working knowledge: tensors, training loops, GPU management, serialization, ONNX deployment, and practical integration patterns for mortgage data pipelines.

---

## Key Concepts

| Concept | Description |
|---|---|
| Tensor | N-dimensional array on CPU or GPU; the basic data unit |
| Autograd | Automatic differentiation; tracks operations for backpropagation |
| DataLoader | Batched, shuffled, multi-process data feeding |
| Dataset | Abstract class for defining how data is accessed |
| Epoch | One full pass through the training dataset |
| Backpropagation | Compute gradients via chain rule using autograd |
| Optimizer | Updates weights using gradients (Adam, SGD, AdamW) |
| ONNX | Open Neural Network Exchange — cross-framework serialization |
| TorchScript | PyTorch's compilation path for production deployment |
| PyTorch Lightning | High-level training framework that wraps raw PyTorch |

---

## PyTorch vs TensorFlow: Ecosystem Comparison

| Dimension | PyTorch | TensorFlow/Keras |
|---|---|---|
| Adoption (2025) | Dominant in research, growing in production | Strong in production, Google ecosystem |
| API style | Pythonic, imperative (eager by default) | Mixed: Keras=imperative, TF core=graph |
| Debugging | Native Python debugger works; intuitive | More complex; TF graph debugging harder |
| Deployment | TorchServe, TorchScript, ONNX | TF Serving, TFLite, SavedModel |
| HuggingFace | PyTorch-first; TF available for most models | Secondary |
| Mobile/Edge | ExecuTorch (PyTorch) | TFLite (TensorFlow) |
| SQL Server PREDICT | Via ONNX export | Via ONNX export |
| Industry (2025) | ~70% ML research papers; ~55% production | ~30% research; ~45% production (legacy) |

**Recommendation for data engineers:** Learn PyTorch fundamentals. HuggingFace, most modern research, and new ML tooling is PyTorch-first. Know TF Serving and the Keras API for legacy systems.

---

## When Do Data Engineers Need PyTorch/TF?

```
Use Case                           Framework       Notes
---------------------------------  --------------  --------------------------------
Tabular ML (loans, credit risk)    scikit-learn/   Neural nets rarely beat XGBoost
                                   XGBoost         for tabular data < 10M rows

Time-series forecasting (LSTM)     PyTorch         LSTMs for CPR/delinquency series

NLP on loan documents              PyTorch via HF  transformers library is PyTorch

Load pre-trained model for         PyTorch/ONNX    Export to ONNX for SQL Server
  SQL Server PREDICT

Deploy model to Snowflake          PyTorch ONNX    Snowflake ML or UDF

Custom architecture research       PyTorch         Flexibility matters here

Production serving (existing TF)   TF Serving      Don't rewrite what works
```

---

## PyTorch Fundamentals

### Tensors

```python
import torch

# Create tensors
x = torch.tensor([1.0, 2.0, 3.0])
matrix = torch.zeros(3, 4)
random = torch.randn(100, 16)           # 100 samples, 16 features

# Device management
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
x = x.to(device)

# Common operations
print(x.shape)        # torch.Size([3])
print(x.dtype)        # torch.float32
print(x.device)       # cuda:0 or cpu

# Tensor from numpy (zero-copy when on CPU)
import numpy as np
arr = np.array([1.0, 2.0, 3.0])
t = torch.from_numpy(arr)          # shares memory
arr_back = t.numpy()               # back to numpy

# Reshape
x = torch.randn(32, 128)
x_flat = x.view(32, -1)           # -1 inferred
x_t = x.transpose(0, 1)           # swap dims
```

### Autograd

```python
# Requires_grad=True tells PyTorch to track operations
x = torch.tensor([2.0, 3.0], requires_grad=True)
y = x ** 2 + 3 * x                 # y = x^2 + 3x
loss = y.sum()
loss.backward()                    # compute gradients
print(x.grad)                      # tensor([7., 9.]) = 2x+3 at x=[2,3]

# In model training, detach predictions from the graph when not training
with torch.no_grad():
    predictions = model(inputs)    # no gradient tracking; saves memory
```

---

## PyTorch Dataset and DataLoader

```python
import torch
from torch.utils.data import Dataset, DataLoader
import pandas as pd
import snowflake.connector
import numpy as np

class LoanDataset(Dataset):
    """Custom Dataset for loan features from Snowflake."""

    def __init__(self, query: str, sf_conn_params: dict):
        conn = snowflake.connector.connect(**sf_conn_params)
        cursor = conn.cursor()
        cursor.execute(query)
        data = cursor.fetchall()
        columns = [desc[0].lower() for desc in cursor.description]
        conn.close()

        df = pd.DataFrame(data, columns=columns)

        feature_cols = ["credit_score", "ltv", "dti", "note_rate",
                        "orig_upb", "months_since_orig"]
        target_col = "delinquent_next_month"

        # Normalize features
        self.X = torch.tensor(
            df[feature_cols].fillna(df[feature_cols].median()).values,
            dtype=torch.float32
        )
        self.y = torch.tensor(df[target_col].values, dtype=torch.float32)

    def __len__(self) -> int:
        return len(self.X)

    def __getitem__(self, idx: int):
        return self.X[idx], self.y[idx]


# Usage
query = """
    SELECT credit_score, ltv, dti, note_rate, orig_upb,
           months_since_orig, delinquent_next_month
    FROM MORTGAGE_DW.ML_FEATURES.MONTHLY_LOAN_STATUS
    WHERE report_date >= '2020-01-01'
"""

dataset = LoanDataset(query, sf_conn_params)
train_size = int(0.8 * len(dataset))
train_ds, val_ds = torch.utils.data.random_split(
    dataset, [train_size, len(dataset) - train_size]
)

train_loader = DataLoader(
    train_ds,
    batch_size=512,
    shuffle=True,
    num_workers=4,           # parallel data loading
    pin_memory=True          # faster CPU->GPU transfer
)
val_loader = DataLoader(val_ds, batch_size=1024, shuffle=False, num_workers=4)
```

---

## PyTorch LSTM for Loan Performance Forecasting

```python
import torch
import torch.nn as nn

class LoanLSTM(nn.Module):
    """
    LSTM for predicting monthly loan delinquency status.
    Input sequence: monthly features for each loan (credit score, LTV, macro factors)
    Output: probability of delinquency in the next month
    """

    def __init__(self, input_size: int, hidden_size: int, num_layers: int,
                 dropout: float = 0.2):
        super().__init__()
        self.hidden_size = hidden_size
        self.num_layers = num_layers

        self.lstm = nn.LSTM(
            input_size=input_size,
            hidden_size=hidden_size,
            num_layers=num_layers,
            batch_first=True,       # input shape: (batch, seq, features)
            dropout=dropout if num_layers > 1 else 0.0,
            bidirectional=False
        )
        self.dropout = nn.Dropout(dropout)
        self.fc = nn.Linear(hidden_size, 1)
        self.sigmoid = nn.Sigmoid()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x shape: (batch_size, seq_len, input_size)
        lstm_out, (h_n, c_n) = self.lstm(x)

        # Use the last hidden state for prediction
        last_hidden = h_n[-1]           # shape: (batch_size, hidden_size)
        out = self.dropout(last_hidden)
        out = self.fc(out)              # shape: (batch_size, 1)
        return self.sigmoid(out).squeeze(1)


# Training loop
def train_lstm(model, train_loader, val_loader, epochs: int = 30):
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model = model.to(device)

    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-5)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(
        optimizer, mode="min", factor=0.5, patience=3
    )
    # Weighted BCE for imbalanced delinquency labels
    pos_weight = torch.tensor([20.0]).to(device)   # ~5% delinquency rate
    criterion = nn.BCEWithLogitsLoss(pos_weight=pos_weight)

    best_val_loss = float("inf")
    for epoch in range(epochs):
        model.train()
        train_loss = 0.0
        for X_batch, y_batch in train_loader:
            X_batch, y_batch = X_batch.to(device), y_batch.to(device)
            optimizer.zero_grad()
            preds = model(X_batch)
            loss = criterion(preds, y_batch)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)  # gradient clipping
            optimizer.step()
            train_loss += loss.item()

        # Validation
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for X_val, y_val in val_loader:
                X_val, y_val = X_val.to(device), y_val.to(device)
                preds = model(X_val)
                val_loss += criterion(preds, y_val).item()

        val_loss /= len(val_loader)
        scheduler.step(val_loss)

        print(f"Epoch {epoch+1:3d} | Train Loss: {train_loss/len(train_loader):.4f} "
              f"| Val Loss: {val_loss:.4f} | LR: {optimizer.param_groups[0]['lr']:.2e}")

        if val_loss < best_val_loss:
            best_val_loss = val_loss
            torch.save(model.state_dict(), "best_loan_lstm.pt")


# Instantiate and train
model = LoanLSTM(input_size=12, hidden_size=64, num_layers=2, dropout=0.2)
# train_lstm(model, train_loader, val_loader)
```

---

## TensorFlow / Keras

### Sequential and Functional API

```python
import tensorflow as tf
from tensorflow import keras

# --- Sequential API (simple, linear stacks) ---
model_seq = keras.Sequential([
    keras.layers.Input(shape=(16,)),
    keras.layers.Dense(128, activation="relu"),
    keras.layers.BatchNormalization(),
    keras.layers.Dropout(0.3),
    keras.layers.Dense(64, activation="relu"),
    keras.layers.Dropout(0.3),
    keras.layers.Dense(1, activation="sigmoid")
], name="loan_default_nn")

model_seq.compile(
    optimizer=keras.optimizers.Adam(learning_rate=1e-3),
    loss="binary_crossentropy",
    metrics=["AUC", "Precision", "Recall"]
)

model_seq.summary()

# --- Functional API (multi-input, branching, residual connections) ---
# Multi-input: structured features + text embedding side-channel
structured_input = keras.Input(shape=(16,), name="structured_features")
text_input = keras.Input(shape=(384,), name="text_embedding")   # sentence-transformer output

x1 = keras.layers.Dense(64, activation="relu")(structured_input)
x1 = keras.layers.BatchNormalization()(x1)

x2 = keras.layers.Dense(64, activation="relu")(text_input)

merged = keras.layers.Concatenate()([x1, x2])
merged = keras.layers.Dense(32, activation="relu")(merged)
output = keras.layers.Dense(1, activation="sigmoid", name="default_prob")(merged)

model_func = keras.Model(
    inputs=[structured_input, text_input],
    outputs=output,
    name="multimodal_loan_default"
)
```

---

## Model Serialization

### PyTorch Save/Load

```python
# Save full model (architecture + weights) — not recommended for production
torch.save(model, "model_full.pt")
loaded = torch.load("model_full.pt")

# Save only state_dict (recommended — portable, not tied to class definition)
torch.save(model.state_dict(), "model_weights.pt")
model.load_state_dict(torch.load("model_weights.pt", map_location=device))
model.eval()

# TorchScript — serialize the computation graph (no Python dependency)
scripted_model = torch.jit.script(model)
scripted_model.save("model_scripted.pt")
loaded_scripted = torch.jit.load("model_scripted.pt")
```

---

## ONNX Export and Cross-Framework Deployment

ONNX (Open Neural Network Exchange) is the key to deploying PyTorch/TF models in SQL Server, Snowflake, and other production environments without a Python runtime.

```python
import torch
import torch.onnx

# Export PyTorch model to ONNX
model.eval()
dummy_input = torch.randn(1, 12, 16)   # (batch=1, seq_len=12, features=16)

torch.onnx.export(
    model,
    dummy_input,
    "loan_lstm.onnx",
    opset_version=17,
    input_names=["loan_sequence"],
    output_names=["delinquency_probability"],
    dynamic_axes={
        "loan_sequence": {0: "batch_size"},         # dynamic batch
        "delinquency_probability": {0: "batch_size"}
    },
    do_constant_folding=True    # optimize constant subgraphs
)

# Verify ONNX model
import onnx
onnx_model = onnx.load("loan_lstm.onnx")
onnx.checker.check_model(onnx_model)
print("ONNX model validated successfully")

# Run with ONNX Runtime (CPU — typically faster than PyTorch on CPU)
import onnxruntime as ort
import numpy as np

session = ort.InferenceSession(
    "loan_lstm.onnx",
    providers=["CUDAExecutionProvider", "CPUExecutionProvider"]
)

input_data = np.random.randn(32, 12, 16).astype(np.float32)  # batch of 32 loans
outputs = session.run(
    ["delinquency_probability"],
    {"loan_sequence": input_data}
)
print(f"Predictions shape: {outputs[0].shape}")   # (32,)
```

---

## ONNX Models in SQL Server — PREDICT Function

SQL Server 2017+ with Machine Learning Services can run ONNX models via `PREDICT`:

```sql
-- Step 1: Load ONNX model binary into SQL Server
DECLARE @model VARBINARY(MAX);
SELECT @model = CAST(BulkColumn AS VARBINARY(MAX))
FROM OPENROWSET(BULK 'C:\Models\loan_lstm.onnx', SINGLE_BLOB) AS ModelFile;

-- Step 2: Store in a models table
INSERT INTO dbo.ML_MODELS (model_name, model_version, model_binary, created_dt)
VALUES ('loan_delinquency_lstm', '1.0.0', @model, GETDATE());

-- Step 3: Score using PREDICT (SQL Server 2017+ with ML Services)
SELECT
    l.loan_id,
    l.report_date,
    p.delinquency_probability
FROM dbo.MONTHLY_LOAN_FEATURES l
CROSS APPLY PREDICT(
    MODEL = (SELECT model_binary FROM dbo.ML_MODELS
             WHERE model_name = 'loan_delinquency_lstm'
             AND model_version = '1.0.0'),
    DATA = l,
    RUNTIME = ONNX
) WITH (delinquency_probability REAL) AS p
WHERE l.report_date = EOMONTH(GETDATE(), -1);

-- Step 4: Persist scores
INSERT INTO dbo.LOAN_DELINQUENCY_SCORES (loan_id, report_date, dlq_probability, score_ts)
SELECT
    l.loan_id,
    l.report_date,
    p.delinquency_probability,
    GETDATE()
FROM dbo.MONTHLY_LOAN_FEATURES l
CROSS APPLY PREDICT(
    MODEL = (SELECT model_binary FROM dbo.ML_MODELS
             WHERE model_name = 'loan_delinquency_lstm'
             AND model_version = '1.0.0'),
    DATA = l,
    RUNTIME = ONNX
) WITH (delinquency_probability REAL) AS p
WHERE l.report_date = EOMONTH(GETDATE(), -1);
```

**Key requirements:** SQL Server 2017+, Machine Learning Services feature installed, ONNX opset <= 12 for SQL Server 2019, opset <= 17 for SQL Server 2022. Model input columns must match the ONNX input tensor names and types exactly.

---

## PyTorch Lightning for Cleaner Training Code

```python
import pytorch_lightning as pl
import torch
import torch.nn as nn
from torchmetrics import AUROC

class LoanDefaultLightning(pl.LightningModule):
    def __init__(self, input_size: int, hidden_size: int = 64,
                 learning_rate: float = 1e-3):
        super().__init__()
        self.save_hyperparameters()

        self.model = nn.Sequential(
            nn.Linear(input_size, hidden_size),
            nn.BatchNorm1d(hidden_size),
            nn.ReLU(),
            nn.Dropout(0.3),
            nn.Linear(hidden_size, 32),
            nn.ReLU(),
            nn.Linear(32, 1)
        )
        self.criterion = nn.BCEWithLogitsLoss(
            pos_weight=torch.tensor([15.0])    # class imbalance
        )
        self.train_auroc = AUROC(task="binary")
        self.val_auroc = AUROC(task="binary")

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.model(x).squeeze(1)

    def training_step(self, batch, batch_idx):
        X, y = batch
        logits = self(X)
        loss = self.criterion(logits, y)
        self.train_auroc(torch.sigmoid(logits), y.int())
        self.log("train_loss", loss, on_step=False, on_epoch=True, prog_bar=True)
        self.log("train_auc", self.train_auroc, on_step=False, on_epoch=True)
        return loss

    def validation_step(self, batch, batch_idx):
        X, y = batch
        logits = self(X)
        loss = self.criterion(logits, y)
        self.val_auroc(torch.sigmoid(logits), y.int())
        self.log("val_loss", loss, prog_bar=True)
        self.log("val_auc", self.val_auroc, prog_bar=True)

    def configure_optimizers(self):
        optimizer = torch.optim.AdamW(
            self.parameters(),
            lr=self.hparams.learning_rate,
            weight_decay=1e-4
        )
        scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
            optimizer, T_max=30
        )
        return {"optimizer": optimizer, "lr_scheduler": scheduler}


# Train with Lightning Trainer (handles GPU, checkpointing, logging)
from pytorch_lightning.callbacks import EarlyStopping, ModelCheckpoint

trainer = pl.Trainer(
    max_epochs=50,
    accelerator="gpu",
    devices=1,
    callbacks=[
        EarlyStopping(monitor="val_auc", mode="max", patience=7),
        ModelCheckpoint(
            monitor="val_auc",
            mode="max",
            filename="loan-default-{epoch:02d}-{val_auc:.4f}",
            save_top_k=3
        )
    ],
    log_every_n_steps=50,
    precision="16-mixed"    # automatic mixed precision
)

model = LoanDefaultLightning(input_size=16)
trainer.fit(model, train_loader, val_loader)
```

---

## Transfer Learning and Fine-Tuning

```python
import torch
import torch.nn as nn
from transformers import AutoModel, AutoTokenizer

class MortgageDocClassifier(nn.Module):
    """
    Fine-tune DistilBERT for mortgage document classification.
    Freeze backbone, train classification head first; then unfreeze.
    """

    def __init__(self, num_classes: int = 7, dropout: float = 0.2):
        super().__init__()
        self.backbone = AutoModel.from_pretrained("distilbert-base-uncased")

        # Freeze backbone initially
        for param in self.backbone.parameters():
            param.requires_grad = False

        hidden_size = self.backbone.config.hidden_size  # 768
        self.classifier = nn.Sequential(
            nn.Dropout(dropout),
            nn.Linear(hidden_size, 256),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(256, num_classes)
        )

    def unfreeze_backbone(self, layers_from_end: int = 2):
        """Gradually unfreeze transformer layers for fine-tuning."""
        transformer_layers = self.backbone.transformer.layer
        for layer in transformer_layers[-layers_from_end:]:
            for param in layer.parameters():
                param.requires_grad = True

    def forward(self, input_ids, attention_mask):
        outputs = self.backbone(input_ids=input_ids, attention_mask=attention_mask)
        # CLS token representation (index 0)
        cls_output = outputs.last_hidden_state[:, 0, :]
        return self.classifier(cls_output)


# Training strategy: warm-up head, then fine-tune backbone
classifier = MortgageDocClassifier(num_classes=7)

# Phase 1: Train only the head (5 epochs)
optimizer_head = torch.optim.Adam(classifier.classifier.parameters(), lr=1e-3)

# Phase 2: Unfreeze last 2 transformer layers + fine-tune all
classifier.unfreeze_backbone(layers_from_end=2)
optimizer_full = torch.optim.AdamW(
    [
        {"params": classifier.backbone.parameters(), "lr": 2e-5},   # low LR for backbone
        {"params": classifier.classifier.parameters(), "lr": 1e-4}  # higher LR for head
    ],
    weight_decay=1e-2
)
```

---

## TF Serving and TorchServe

### TorchServe Quick Reference

```bash
# Package model for TorchServe
torch-model-archiver \
    --model-name loan_default \
    --version 1.0 \
    --model-file model.py \
    --serialized-file model_weights.pt \
    --handler custom_handler.py \
    --extra-files vocab.json \
    --export-path model_store

# Start server
torchserve --start \
    --model-store model_store \
    --models loan_default=loan_default.mar \
    --ncs

# Score
curl -X POST http://localhost:8080/predictions/loan_default \
     -H "Content-Type: application/json" \
     -d '{"loan_id": "2025-NC-001", "features": [720, 80, 35, 6.5, 425000, 24]}'
```

### TF Serving Quick Reference

```python
# Save model in SavedModel format
model.save("tf_saved_model/loan_default/1")  # version directory required

# docker run tensorflow/serving:latest with volume mount
# Query via REST
import requests, json

payload = {"instances": [[720, 80, 35, 6.5, 425000, 24]]}
response = requests.post(
    "http://localhost:8501/v1/models/loan_default:predict",
    data=json.dumps(payload)
)
print(response.json())   # {"predictions": [[0.0423]]}
```

---

## Interview Q&A

**Q1: As a data engineer, when would you actually use PyTorch vs. XGBoost for a mortgage ML problem?**

Use XGBoost (or LightGBM) for tabular data — credit risk scoring, default prediction, prepayment modeling. Tree ensembles consistently outperform neural networks on tabular mortgage data because the feature relationships are non-smooth and tree splits handle them naturally. PyTorch becomes the right choice when: (1) input is sequential — monthly loan performance history where temporal dependencies matter (LSTM, Transformer); (2) input is unstructured — images of property photos, PDFs of loan documents (CNNs, BERT); (3) you need to fine-tune a pre-trained HuggingFace model; (4) the prediction task requires capturing complex cross-feature interactions at scale where tree depth would need to be impractically large. The rule of thumb: if you can express your features in a flat row, try XGBoost first.

---

**Q2: Explain the PyTorch training loop: what happens in each step and why?**

The canonical loop has four steps per batch: (1) `optimizer.zero_grad()` — clear gradients accumulated from the previous batch (PyTorch accumulates by default; forgetting this corrupts weight updates); (2) Forward pass — `outputs = model(inputs)` — compute predictions; (3) Loss computation — `loss = criterion(outputs, targets)` — scalar measure of error; (4) `loss.backward()` — backpropagate: PyTorch's autograd traverses the computation graph and computes `∂loss/∂parameter` for every parameter with `requires_grad=True`; (5) `optimizer.step()` — apply the parameter update rule (e.g., `param -= lr * param.grad` for SGD). The `with torch.no_grad()` context in validation skips gradient computation, saving ~50% memory and ~30% time.

---

**Q3: What is ONNX and how does it enable deploying a PyTorch model inside SQL Server?**

ONNX (Open Neural Network Exchange) is a standardized format representing neural network architectures as a computation graph with vendor-neutral operators. Exporting to ONNX via `torch.onnx.export()` serializes the model's architecture and weights into a `.onnx` file. SQL Server 2017+ Machine Learning Services includes an ONNX runtime (Microsoft.ML.OnnxRuntime) that can execute these graphs directly in the database process. You load the binary into a `VARBINARY(MAX)` column and call the `PREDICT` T-SQL function — no Python or R runtime required at scoring time. This is valuable for a secondary mortgage market data warehouse where IT may not permit external ML service calls during month-end reporting.

---

**Q4: What is the vanishing gradient problem and why does it matter for LSTM-based loan performance forecasting?**

In plain RNNs, gradients backpropagated through long sequences are multiplied by the weight matrix at each time step. If eigenvalues of that matrix are < 1, gradients shrink exponentially with sequence length — by time step 100, the gradient signal from that step is effectively zero, meaning the model cannot learn long-range dependencies. LSTM solves this with a cell state (`c_t`) and gating mechanism: the forget gate controls what to erase, the input gate controls new information, and the output gate controls what to expose as the hidden state. The cell state flows through time with only additive (not multiplicative) updates, providing a gradient highway. For loan performance, a loan originating in 2020 may have macro events (COVID forbearance in month 3, rate shock in month 18) that remain predictive of default in month 36 — long-range dependencies that LSTMs handle but vanilla RNNs cannot.

---

**Q5: What is gradient clipping and why is it used in LSTM training?**

LSTMs can suffer from exploding gradients (the opposite of vanishing) — gradients grow exponentially and destabilize training, producing NaN losses. `torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)` scales all gradients proportionally if their total L2 norm exceeds `max_norm`. This is called between `loss.backward()` and `optimizer.step()`. It does not prevent the model from learning large weight updates over time — it just prevents catastrophically large single-step updates. For mortgage time-series, loan cohorts with unusual vintage behavior (e.g., pre-2008 subprime data mixed with post-2010 QM data) create high-variance gradients that benefit from clipping.

---

**Q6: How does transfer learning work and why is it practical for mortgage document classification with small labeled datasets?**

Pre-trained models like DistilBERT have learned general English language representations from hundreds of billions of tokens. Their early layers encode syntax and morphology; later layers encode semantics. Transfer learning reuses these weights as a starting point. For a mortgage document classifier with 2,000 labeled examples: (1) load `distilbert-base-uncased` pre-trained weights; (2) freeze the backbone (no gradient updates); (3) train only a small classification head on your 2,000 examples — the head converges in a few epochs because the features it receives are already high-quality; (4) optionally unfreeze the last 2–3 transformer layers with a very low learning rate (2e-5) to adapt the representation to mortgage vocabulary. This achieves 90%+ accuracy with 2,000 examples versus needing 100,000+ to train from scratch.

---

**Q7: What is the difference between `torch.save(model, ...)` and `torch.save(model.state_dict(), ...)` and which is recommended for production?**

`torch.save(model, path)` uses Python's `pickle` to serialize the entire model object including the class definition and weights. Loading requires the exact same Python class to be importable in the target environment — fragile across code refactors. `torch.save(model.state_dict(), path)` serializes only the parameter tensors as a dictionary keyed by layer name. It is a simple tensor archive with no dependency on your model class. For production: always save the `state_dict`, keep the model class definition in version control, and reconstruct the model object at load time with `model.load_state_dict(torch.load(path))`. For even more portability (no PyTorch dependency), export to ONNX.

---

**Q8: How would you deploy a PyTorch model to score loans in Snowflake without moving data out of Snowflake?**

Three paths: (1) **ONNX + Snowflake Python UDF** — export the model to ONNX, upload the `.onnx` file to a Snowflake stage, load it in a Python UDF using `onnxruntime`. The UDF runs in a Snowflake virtual warehouse process. (2) **Snowpark Python UDF with torch** — if the model is small, load the PyTorch model directly in a Snowpark UDF with `torch` available as a package. Suitable for models < 100MB and batch scoring. (3) **Snowpark Container Services** — for large models (LLMs, transformers), deploy a Docker container with GPU support inside Snowflake's network boundary. The container has access to Snowflake data via an internal connection, and the UDF routes requests to the container. Option 3 is the most powerful but requires Snowpark Container Services (available in Business Critical edition).

---

**Q9: What is PyTorch Lightning and what problems does it solve for a data engineering team?**

Raw PyTorch requires writing boilerplate: the training loop, validation loop, GPU device management, gradient accumulation, checkpointing, early stopping, and distributed training setup. PyTorch Lightning abstracts all of this into a `LightningModule` (your model + training/validation steps) and a `Trainer` (all the training infrastructure). A data engineering team benefits because: (1) less custom code to maintain and debug; (2) switching from CPU to GPU to multi-GPU or TPU is a single `Trainer(accelerator=..., devices=...)` change; (3) logging to MLflow, TensorBoard, or W&B is built-in; (4) reproducible training via `seed_everything(42)`; (5) `precision="16-mixed"` automatic mixed precision is one argument. The team focuses on the model and data logic, not training infrastructure.

---

**Q10: For ONNX export, what are the key considerations to ensure the model works correctly in SQL Server's PREDICT function?**

Key considerations: (1) **Opset version** — SQL Server 2019 supports up to ONNX opset 12; SQL Server 2022 supports opset 17. Export with `opset_version=12` for maximum compatibility. (2) **Dynamic axes** — declare dynamic batch size with `dynamic_axes` parameter, otherwise the model is fixed to the export batch size. (3) **Data types** — SQL Server PREDICT expects `REAL` (float32). Ensure model inputs/outputs are `torch.float32`, not `float64`. (4) **Input column matching** — the input tensor names in ONNX must exactly match the column aliases in the `WITH` clause of `PREDICT`. (5) **No unsupported ops** — avoid custom CUDA ops, dynamic control flow (`if tensor_value > 0`), or Python-specific operators; use `torch.jit.script` to catch these before export. (6) **Model size** — VARBINARY(MAX) supports up to 2GB, but large models may hit memory limits in the SQL Server process; keep inference models under 500MB.

---

## Pro Tips

- **Profile before optimizing.** Use `torch.profiler.profile()` to identify whether your training bottleneck is in the data loader (CPU-bound) or the forward/backward pass (GPU-bound). Adding more workers to `DataLoader` only helps if the GPU is waiting on data.
- **Use `pin_memory=True` in DataLoader.** When using a GPU, this allocates data loader tensors in pinned (page-locked) memory, enabling asynchronous CPU-to-GPU transfer and typically giving 10–20% throughput improvement.
- **ONNX simplification.** Run `onnx-simplifier` (`pip install onnxsim`) after export: `onnxsim loan_lstm.onnx loan_lstm_simplified.onnx`. It folds constants and removes redundant nodes, producing a smaller, faster model that is easier for SQL Server's runtime to execute.
- **Mixed precision in Keras.** `keras.mixed_precision.set_global_policy("mixed_float16")` before building the model enables fp16 forward pass with fp32 weight storage — no other code changes required.
- **Separate feature engineering from model code.** Keep your preprocessing (normalization params, vocabulary) inside the ONNX graph by exporting with `torch.nn.Sequential` wrappers for standardization. This avoids preprocessing skew between training and SQL Server inference.
- **Validate ONNX outputs against PyTorch.** After export, run the same input through both the PyTorch model and the ONNX runtime and assert `np.allclose(pt_output, onnx_output, atol=1e-5)`. Subtle numerical differences from fp32/fp16 conversions should be caught before production.
- **For Snowflake ML, evaluate before PyTorch.** Snowflake ML Functions (FORECAST, ANOMALY_DETECTION, CLASSIFY) handle common time-series and classification tasks with zero model code. Only write PyTorch when the problem genuinely requires it — custom architectures, pre-trained models, or sequential data.
