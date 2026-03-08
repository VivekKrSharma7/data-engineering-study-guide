# Deep Learning & Neural Networks Overview

[← Back to Index](README.md)

---

## Overview

Deep learning is a subfield of machine learning that uses artificial neural networks with many layers (hence "deep") to learn hierarchical representations from data. While traditional ML algorithms require handcrafted feature engineering, deep learning models can discover relevant features automatically — provided you supply enough data and compute.

For a senior data engineer, the practical question is never "how do I derive backpropagation gradients by hand?" It is: "what data pipeline infrastructure does deep learning require, when does it justify the complexity over XGBoost, and how do I operate these systems at scale?" This guide answers those questions while building enough conceptual depth to hold your own in any technical interview.

---

## The Neuron: Conceptual Foundation

A single artificial neuron (perceptron) computes a weighted sum of its inputs, adds a bias, and passes the result through an **activation function**:

```
output = activation( w₁x₁ + w₂x₂ + ... + wₙxₙ + b )
```

Where:
- `x₁..xₙ` = input features
- `w₁..wₙ` = learned weights
- `b` = learned bias
- `activation` = non-linear function

Without activation functions, stacking layers would just produce another linear model. Non-linearity is what gives deep networks their expressive power.

---

## Activation Functions

| Function | Formula | Range | Use case |
|---|---|---|---|
| ReLU | `max(0, x)` | [0, ∞) | Default for hidden layers; fast, sparse activation |
| Leaky ReLU | `max(0.01x, x)` | (-∞, ∞) | Fixes "dying ReLU" problem |
| Sigmoid | `1 / (1 + e⁻ˣ)` | (0, 1) | Binary classification output layer |
| Softmax | `eˣⁱ / Σeˣʲ` | (0, 1), sums to 1 | Multi-class classification output layer |
| Tanh | `(eˣ - e⁻ˣ)/(eˣ + e⁻ˣ)` | (-1, 1) | Hidden layers in RNNs; zero-centered |
| GELU | Smooth approx of ReLU | (-∞, ∞) | Transformers, modern architectures |

---

## Network Architecture

### Feedforward Neural Network (FNN)

The simplest architecture: layers flow in one direction — input → hidden → output. No cycles.

```
Input Layer        Hidden Layer 1      Hidden Layer 2      Output Layer
[FICO]  ─────┐
[LTV]   ──────╔══════╗           ╔══════╗
[DTI]   ──────║  64  ║── ReLU ──║  32  ║── ReLU ──[Sigmoid]──► P(default)
[Age]   ──────╚══════╝           ╚══════╝
[Rate]  ─────┘
```

### Key Layer Types

| Layer Type | What it Does | Use Case |
|---|---|---|
| Dense (Fully Connected) | Every neuron connects to every neuron in the next layer | Classification, regression heads |
| Convolutional (Conv2D) | Detects local spatial patterns with shared weights | Image data, pattern recognition |
| Recurrent (RNN/LSTM/GRU) | Maintains hidden state across time steps | Sequential data, time series |
| Embedding | Maps discrete tokens/IDs to dense vectors | NLP, categorical features |
| Batch Normalization | Normalizes activations within a mini-batch | Stabilizes training, allows higher LR |
| Dropout | Randomly zeroes fraction of neurons during training | Regularization to prevent overfitting |

---

## Backpropagation and Gradient Descent

Training a neural network means finding weights that minimize a **loss function** (e.g., binary cross-entropy for classification, MSE for regression).

**Gradient descent** updates weights in the direction that reduces the loss:

```
w_new = w_old - learning_rate * ∂Loss/∂w
```

**Backpropagation** efficiently computes `∂Loss/∂w` for every weight in the network using the chain rule of calculus, propagating the error signal backwards from the output layer to the input layer.

### Optimization Algorithms

| Optimizer | Key Idea | When to Use |
|---|---|---|
| SGD | Update after each mini-batch | Simple baseline; needs LR tuning |
| SGD + Momentum | Accumulates gradient direction | Better convergence than plain SGD |
| Adam | Adaptive learning rates per parameter | Default choice for most tasks |
| AdamW | Adam + weight decay regularization | Transformers, large models |
| RMSProp | Adapts LR to gradient magnitude | RNNs, non-stationary problems |

---

## Convolutional Neural Networks (CNNs)

CNNs apply small filters (kernels) that slide across input data, detecting local patterns (edges, textures, motifs). Because the same filter is applied everywhere, CNNs have far fewer parameters than a fully connected network on image data.

**Architecture pattern:**
```
Input → [Conv → ReLU → Pooling]ₓₙ → Flatten → Dense → Output
```

**DE-relevant CNN use cases:**
- Document image classification (classify loan document types: W-2, 1003, title commitment)
- Handwritten form recognition for legacy mortgage paper files
- Anomaly detection in time-series data plotted as spectrogram-style 2D images

---

## Recurrent Neural Networks (RNNs) and LSTMs

Standard feedforward networks cannot handle sequences — they have no memory of previous inputs. RNNs maintain a hidden state that carries information from previous time steps.

**Vanilla RNN limitation:** Gradients vanish or explode over long sequences (long-term dependencies are lost).

**LSTM (Long Short-Term Memory)** solves this with three gates:
- **Forget gate:** decides what to discard from the cell state
- **Input gate:** decides what new information to add
- **Output gate:** decides what to expose as output

```
Cell State   ────────────────────────────────────────────────►
                   ↑ forget           ↑ input           ↓ output
                [forget gate] → [input gate] → [output gate]
                      ↑               ↑               ↑
Hidden State ────────────────────────────────────────────────►
```

**GRU (Gated Recurrent Unit):** Simpler than LSTM with only two gates. Similar performance, faster to train.

### MBS Time-Series Application

For modeling monthly loan performance sequences:

```python
import torch
import torch.nn as nn

class LoanPerformanceLSTM(nn.Module):
    """
    Predicts prepayment probability at each time step
    given a sequence of monthly loan state observations.
    Input shape: (batch_size, sequence_length, n_features)
    """
    def __init__(self, input_size: int, hidden_size: int = 64,
                 num_layers: int = 2, dropout: float = 0.2):
        super().__init__()
        self.lstm = nn.LSTM(
            input_size=input_size,
            hidden_size=hidden_size,
            num_layers=num_layers,
            batch_first=True,
            dropout=dropout
        )
        self.batch_norm = nn.BatchNorm1d(hidden_size)
        self.output_head = nn.Sequential(
            nn.Linear(hidden_size, 32),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(32, 1),
            nn.Sigmoid()  # prepayment probability
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: (batch, seq_len, input_size)
        lstm_out, _ = self.lstm(x)
        # Use only the last time step's output
        last_hidden = lstm_out[:, -1, :]
        normed = self.batch_norm(last_hidden)
        return self.output_head(normed).squeeze(-1)
```

---

## Regularization Techniques

| Technique | Mechanism | Typical Value |
|---|---|---|
| Dropout | Zero out random fraction of neurons during training | 0.2–0.5 |
| Batch Normalization | Normalize activations per mini-batch | (always before activation) |
| L2 Weight Decay | Penalize large weights in loss function | 1e-4 to 1e-2 |
| Early Stopping | Stop training when validation loss stops improving | patience=10 epochs |
| Data Augmentation | Artificially expand training set | Domain-specific |
| Gradient Clipping | Cap gradient magnitude to prevent explosion | max_norm=1.0 for RNNs |

---

## Full PyTorch Training Loop

```python
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset
import numpy as np

def train_model(
    model: nn.Module,
    X_train: np.ndarray,
    y_train: np.ndarray,
    X_val: np.ndarray,
    y_val: np.ndarray,
    epochs: int = 50,
    batch_size: int = 512,
    learning_rate: float = 1e-3,
    device: str = "cuda" if torch.cuda.is_available() else "cpu"
):
    model = model.to(device)

    # Convert numpy arrays to tensors
    train_ds = TensorDataset(
        torch.FloatTensor(X_train).to(device),
        torch.FloatTensor(y_train).to(device)
    )
    val_ds = TensorDataset(
        torch.FloatTensor(X_val).to(device),
        torch.FloatTensor(y_val).to(device)
    )
    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True)
    val_loader   = DataLoader(val_ds,   batch_size=batch_size, shuffle=False)

    optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate,
                                  weight_decay=1e-4)
    criterion = nn.BCELoss()
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(
        optimizer, patience=5, factor=0.5, verbose=True
    )

    best_val_loss = float("inf")
    patience_counter = 0
    PATIENCE = 10

    for epoch in range(epochs):
        # --- Training phase ---
        model.train()
        train_loss = 0.0
        for X_batch, y_batch in train_loader:
            optimizer.zero_grad()
            preds = model(X_batch)
            loss = criterion(preds, y_batch)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            optimizer.step()
            train_loss += loss.item() * len(X_batch)

        # --- Validation phase ---
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for X_batch, y_batch in val_loader:
                preds = model(X_batch)
                val_loss += criterion(preds, y_batch).item() * len(X_batch)

        train_loss /= len(train_ds)
        val_loss   /= len(val_ds)
        scheduler.step(val_loss)

        print(f"Epoch {epoch+1:3d} | Train Loss: {train_loss:.4f} | "
              f"Val Loss: {val_loss:.4f}")

        # Early stopping
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            torch.save(model.state_dict(), "best_model.pt")
            patience_counter = 0
        else:
            patience_counter += 1
            if patience_counter >= PATIENCE:
                print(f"Early stopping at epoch {epoch+1}")
                break

    # Reload best checkpoint
    model.load_state_dict(torch.load("best_model.pt"))
    return model
```

---

## Frameworks Comparison

| Framework | Strengths | When to Use |
|---|---|---|
| PyTorch | Pythonic, dynamic graph, research-friendly | New model architectures, research, most production DL |
| TensorFlow / Keras | Mature ecosystem, TFX for production, TFLite for edge | Enterprise teams with TF expertise, mobile deployment |
| JAX | Functional, auto-grad, XLA compilation | High-performance research, Google TPU workloads |
| ONNX | Framework-agnostic model serialization | Cross-framework deployment, inference optimization |
| TorchScript | Serialize PyTorch models for C++ inference | Low-latency serving without Python runtime |

**DE recommendation:** Learn PyTorch's DataLoader/Dataset APIs deeply — that interface is where your pipeline work ends and the model training begins. Understand ONNX for serving serialization.

---

## GPU vs. CPU Considerations for Data Engineers

| Scenario | Recommendation |
|---|---|
| Training large LSTM on 10M loan records | GPU required (NVIDIA A100 or V100); training on CPU takes 10–100x longer |
| Batch inference of XGBoost scores overnight | CPU is fine; XGBoost CPU inference is fast |
| Real-time LSTM inference at API layer | GPU preferred; CPU feasible with optimized ONNX runtime for small models |
| Data preprocessing / feature computation | CPU (GPU offers minimal benefit; I/O bound anyway) |
| Transformer fine-tuning on document data | Multi-GPU recommended; minimum 1 A100 (40GB VRAM) for BERT-scale |

**Practical DE concerns:**
- GPU memory (VRAM) limits batch size; reduce batch size if CUDA OOM errors appear.
- Data loading is often the training bottleneck — use `num_workers > 0` in DataLoader and pin memory (`pin_memory=True`) when training on GPU.
- Store large training datasets in Parquet on S3/Azure; never load full datasets into GPU memory.

---

## Data Engineering Pipeline for Deep Learning

```
Raw Data (SQL Server / Snowflake)
        │
        ▼
[dbt Feature Models]
  - Point-in-time correct features
  - Sequence construction for LSTM
  - Label generation
        │
        ▼
[Export to Parquet — partitioned by vintage/date]
  - Stored on Azure Blob / S3
  - Typically 50–500 GB for a mortgage portfolio
        │
        ▼
[PyTorch Dataset / DataLoader]
  - Reads Parquet shards with pandas or pyarrow
  - Applies in-memory normalization
  - Constructs sequence tensors (LSTM input)
        │
        ▼
[GPU Training Cluster]
  - Azure ML / SageMaker / Databricks
  - Logs metrics to MLflow
        │
        ▼
[Model Registry — MLflow]
  - Stores model artifact (.pt file)
  - Tracks hyperparameters, metrics, data hash
        │
        ▼
[Inference Service — FastAPI + ONNX Runtime]
  - Converts .pt to ONNX for optimized inference
  - Writes scores back to Snowflake
```

---

## When to Use Deep Learning vs. Traditional ML

**Use deep learning when:**
- You have > 100,000 training examples (preferably millions).
- Input data is unstructured: text, images, audio, raw time series.
- Feature engineering is difficult or prohibitively expensive.
- State-of-the-art accuracy justifies infrastructure complexity.
- Sequence modeling is required (loan performance month-by-month history).

**Stick with traditional ML (XGBoost, LightGBM) when:**
- Your dataset is tabular with well-engineered features.
- You have < 50,000 training examples.
- Interpretability is required by regulation (SR 11-7 model risk management).
- Training time and infrastructure costs are constrained.
- You need fast iteration cycles (hours, not days).

**In mortgage/MBS contexts:** LSTM is worth the investment for survival analysis on multi-year loan performance sequences. For point-in-time default classification, XGBoost almost always wins on tabular data.

---

## Use Cases in Mortgage / Secondary Market Data

| Use Case | Architecture | Notes |
|---|---|---|
| Prepayment speed forecasting | LSTM / Temporal CNN | Monthly CPR prediction; sequence length = loan age |
| Default probability | Feedforward NN or XGBoost | Tabular features; SHAP for explainability |
| Document classification | CNN or fine-tuned BERT | Classify: 1003, W-2, title, appraisal |
| OCR + NLP on loan docs | CNN (vision) + BERT (NLP) | Extract fields from scanned PDFs |
| Anomaly detection in pipeline data | Autoencoder | Flag unusual feature distributions; detect data quality issues |
| Rate lock pricing | Deep regression | Multi-feature non-linear pricing models |

---

## Interview Q&A

**Q1: What is backpropagation, and why does a data engineer need to understand it conceptually?**

**A:** Backpropagation is the algorithm used to compute gradients of the loss function with respect to every weight in the network. It applies the chain rule of calculus backwards from the output layer to the input layer, efficiently computing how much each weight contributed to the prediction error.

A data engineer does not need to implement backpropagation, but they need to understand it for two reasons. First, understanding that gradients can vanish over long sequences explains why vanilla RNNs fail on long loan histories and why LSTMs exist — this informs architecture choices you will discuss with data scientists. Second, understanding that backpropagation requires the full computational graph to be held in memory explains why GPU VRAM is a hard constraint and why batch size is a tunable parameter rather than "just use the full dataset."

---

**Q2: Explain the vanishing gradient problem and how LSTMs solve it.**

**A:** In a deep network or an RNN processing long sequences, gradients are multiplied through many layers (or time steps) during backpropagation. If those multiplications involve values less than 1 — which is typical for sigmoid and tanh activations — the gradient signal shrinks exponentially. By the time it reaches the early layers, it is near zero, and those weights stop learning. This is the vanishing gradient problem.

LSTMs solve it by introducing a cell state — a separate memory pathway that flows through time with only additive (not multiplicative) interactions. The forget gate can output values close to 1, allowing the cell state to carry information across hundreds of time steps without the signal decaying. Gradients flow back through the cell state highway relatively intact, enabling the model to learn long-range dependencies in loan sequences (e.g., that a loan's payment history 24 months ago is predictive of current prepayment risk).

---

**Q3: What is batch normalization and why does it help training?**

**A:** Batch normalization normalizes the activations of a layer across the current mini-batch to have zero mean and unit variance, then applies learned scale and shift parameters. It is typically applied after a linear transformation and before the activation function.

Benefits: (1) Reduces internal covariate shift — each layer sees inputs with a stable distribution regardless of how earlier layers are updating, allowing higher learning rates. (2) Acts as mild regularization, reducing the need for dropout. (3) Makes the network less sensitive to weight initialization. (4) Speeds up training significantly on large datasets.

For data engineers, batch normalization means that batch size is not a free hyperparameter — very small batches produce noisy normalization statistics. When GPU memory is tight and batch size must be reduced, layer normalization (which normalizes across features rather than across the batch) is a common alternative used in transformers.

---

**Q4: A data scientist wants to train a 2-billion-parameter model on 5 years of monthly loan performance data. What data pipeline concerns do you raise?**

**A:** Several significant concerns:

First, data volume and format — 5 years of monthly loan-level data for a large servicer can be tens of billions of rows. I would assess whether the current storage format (SQL Server row store) is appropriate for sequential reads, and likely migrate training data to Parquet files on cloud object storage, partitioned by origination vintage.

Second, sequence construction — LSTM training requires constructing fixed-length sequences of monthly observations per loan. This aggregation step is expensive and must be done carefully to avoid future leakage. I would build a dbt model or Spark job that produces `(loan_id, sequence_of_monthly_features, label)` tuples.

Third, data loading throughput — at 2B parameters, the GPU will be compute-bound, meaning data loading must keep pace. I would implement multi-worker DataLoaders, Parquet streaming with pyarrow, and pin_memory for GPU transfers. If data loading is still a bottleneck, I would consider a petastorm or WebDataset format optimized for sequential streaming.

Fourth, data versioning — I would snapshot the exact training dataset (with a hash), register it in MLflow, and store it immutably on blob storage. If the model is retrained, it trains on a new snapshot, not a "live" query against the production database.

Fifth, regulatory concerns — SR 11-7 model risk management in the mortgage industry requires model documentation and auditability. I would ensure the data pipeline produces a complete audit trail of every transformation applied to training data.

---

**Q5: What is dropout and when should you NOT use it?**

**A:** Dropout randomly sets a fraction (e.g., 20%) of neuron outputs to zero during each training forward pass. This prevents any single neuron from becoming overly specialized and forces the network to learn redundant representations. It acts as an ensemble of many different sub-networks.

Situations where you should not use or should reduce dropout: (1) At inference/prediction time — always call `model.eval()` before running inference; PyTorch disables dropout automatically in eval mode. Forgetting this is a common production bug that makes predictions nondeterministic. (2) When the network is already underfitting — adding regularization to a model that is not yet fitting training data well makes the underfitting worse. (3) After batch normalization layers — batch norm already provides regularization; stacking both can over-regularize. (4) In the output layer — the final prediction layer should never have dropout.

---

**Q6: How do you build a data pipeline that feeds a PyTorch model training loop from a Snowflake feature table?**

**A:** The general pattern: (1) Run a Snowflake query to export the feature table to Parquet files on S3 or Azure Blob Storage. I use the Snowflake COPY INTO command with Parquet format, which is fast and produces columnar files ideal for sequential reads. (2) Build a custom PyTorch Dataset class that reads from these Parquet files using pyarrow, applies normalization (using statistics computed only on the training split), and returns tensors. (3) Use DataLoader with `num_workers=4` (or higher) and `pin_memory=True` for GPU training. (4) Never query Snowflake directly from the training loop — latency and compute costs are prohibitive; always export first.

```python
from torch.utils.data import Dataset
import pyarrow.parquet as pq
import numpy as np, torch, pathlib

class LoanParquetDataset(Dataset):
    def __init__(self, parquet_dir: str, feature_cols: list, label_col: str,
                 scaler=None):
        files = sorted(pathlib.Path(parquet_dir).glob("*.parquet"))
        tables = [pq.read_table(f, columns=feature_cols + [label_col])
                  for f in files]
        import pyarrow as pa
        table = pa.concat_tables(tables)
        df = table.to_pandas()
        self.X = torch.FloatTensor(
            scaler.transform(df[feature_cols].values) if scaler
            else df[feature_cols].values.astype(np.float32)
        )
        self.y = torch.FloatTensor(df[label_col].values)

    def __len__(self):  return len(self.y)
    def __getitem__(self, idx):  return self.X[idx], self.y[idx]
```

---

**Q7: What is the difference between an autoencoder and a standard feedforward network? What would you use an autoencoder for in a data pipeline?**

**A:** A standard feedforward network maps inputs to labels in a supervised setting. An autoencoder is trained to reconstruct its own input through a bottleneck: the encoder compresses the input to a low-dimensional latent representation, and the decoder reconstructs the original input from that representation. The training signal is reconstruction error, not external labels — making it unsupervised.

In data pipeline contexts: (1) **Anomaly detection** — train the autoencoder on normal loan data; at inference, loans with high reconstruction error are anomalies (unusual feature combinations that the model never learned to reconstruct well). This is useful for detecting data quality issues or genuinely unusual loans before they enter a pricing model. (2) **Dimensionality reduction** — for high-dimensional feature spaces, the encoder's latent representation can be a compact, dense embedding fed to downstream models. (3) **Missing value imputation** — denoising autoencoders can be trained to reconstruct complete feature vectors from partially masked inputs.

---

**Q8: Your LSTM model trains fine but performs much worse in production than in validation. What do you investigate?**

**A:** This is a training-serving skew problem, possibly compounded by data drift. My investigation steps:

First, I check whether the sequence construction logic is identical in the training pipeline and the serving pipeline. Differences in how monthly sequences are assembled, how missing months are handled, or how the observation date is defined frequently cause this gap.

Second, I check whether the same normalization statistics are applied at serving time as at training time. The scaler must be trained on the training data only and then serialized alongside the model artifact, not refit at serving time.

Third, I compare feature distributions between the validation period and the current production period. If the production data is from a different rate environment or economic cycle than the training data, model drift is expected — the solution is retraining on more recent data.

Fourth, I check whether `model.eval()` is called before inference. If dropout is still active in production, predictions are noisy and differ from validation results.

Fifth, I verify that the label definition matches. If the validation label was "90+ DPD within 6 months" but production predictions are evaluated against a different lookback window, the apparent degradation is a metric mismatch, not true model deterioration.

---

**Q9: Explain batch size as a hyperparameter. What are the tradeoffs between large and small batch sizes?**

**A:** Batch size is the number of training examples processed before updating model weights. It is a critical hyperparameter with multiple tradeoffs:

Large batch size (512, 1024, 2048): More stable gradient estimates (less noise), better hardware utilization (GPU occupancy), faster wall-clock training per epoch. However, large batches often converge to sharp minima that generalize poorly (they can get "stuck" in the loss landscape). Requires proportionally larger learning rates (linear scaling rule: if you double batch size, double the learning rate).

Small batch size (16, 32, 64): Noisy gradient estimates that act as regularization, helping escape sharp minima and find flatter, better-generalizing solutions. Lower memory requirements — critical when GPU VRAM is the bottleneck. Slower per-epoch wall time since GPU utilization is lower.

For mortgage model training in practice: start with batch size 256 or 512, use AdamW, and add learning rate warmup over the first few epochs. If validation performance is poor, try reducing batch size as a regularization strategy before adding dropout.

---

**Q10: How does early stopping work and why is it a regularization technique?**

**A:** Early stopping monitors validation loss (or a validation metric like AUC) after each training epoch. If validation performance does not improve for a defined number of epochs (the patience), training is halted and the model weights from the best validation epoch are restored.

It is a regularization technique because training loss always decreases with more epochs — the model will eventually memorize training data if given unlimited epochs. Validation loss typically decreases for a while and then begins increasing as overfitting sets in. Early stopping exits training at the point where the model has learned genuine patterns (low training loss) without yet having memorized training noise (still good validation performance).

From a DE perspective: always checkpoint the best model weights (not just the final weights) during training. Use a cloud object storage path for checkpoints so they survive training job failures and are accessible for model registration. Include the epoch number and validation metric value in the checkpoint filename for traceability.

---

## Pro Tips

- Always call `model.eval()` before running inference and `model.train()` before each training epoch. Forgetting `model.eval()` is one of the most common silent production bugs in PyTorch — dropout stays active and predictions become stochastic.
- GPU OOM errors almost always mean batch size is too large. Halve the batch size before investigating anything else.
- The DataLoader is where most deep learning pipeline performance is lost. Profile it with `num_workers=0` vs `num_workers=4` before tuning model hyperparameters.
- ONNX export is the standard hand-off between DS (PyTorch) and DE (inference serving). Learn the export API; know that dynamic axes must be declared for variable-length sequences.
- For regulatory environments (SR 11-7): deep learning models are "black boxes" by default. Budget time for SHAP or integrated gradients explanations. Regulators will ask for feature attribution.
- Serialize your feature scaler alongside the model artifact. A deserialized model without its scaler is useless for inference.
- LSTMs are sensitive to sequence length. For very long sequences (> 200 time steps), consider temporal convolutions or transformer architectures instead — they handle long-range dependencies without gradient vanishing and train faster on modern hardware.
- In Snowflake, use the COPY INTO ... (FORMAT = PARQUET) command for training data exports. It produces columnar files at high throughput and integrates naturally with PyTorch's DataLoader pattern.
