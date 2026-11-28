# Status (tạm thời)

File ghi tình hình làm việc, sẽ xoá khi xong đợt này. Cập nhật lần cuối: 2026-11-28.

## Đã xong, đã push lên `main`

| Commit | Nội dung |
|---|---|
| `f7ff475`, `c677f47` | migrate giữ linuxbrew trên PATH (block trong `env.local`, nối cuối); doctor kiểm tra theo session mới (đọc `PATH=` trong `/etc/environment`) |
| `1075061` | `--keep-linuxbrew` / `--drop-linuxbrew`; report liệt kê các lệnh chỉ có trong brew |
| `b669ea6` | doctor WARN khi zsh khởi động quá 600 ms |
| `fcbf9de` | WSL1: không chạy `mise activate` lúc khởi động và mỗi prompt; dùng cache môi trường mise, vào thư mục có `mise.toml` thì chuyển sang activate bình thường. Gate fzf-tab đọc init cache, không chạy fzf |
| `a91e244` | `source ~/.zshrc` / `~/.bashrc` không lỗi, giữ nguyên chế độ |
| `b3a9631` | sửa PATH theo thời gian tuyến tính (trước đó chậm theo bình phương độ dài PATH, mất vài giây trên PATH dài của WSL) |
| `c1266f0` | trên WSL, doctor đo thời gian khởi động với PATH có các entry Windows `/mnt/...` |
| `0ba8740` | `_df_wsl_filter` tách PATH tuyến tính; test đo khởi động với filter bật |
| `9edb830` | `dotfiles update` chạy installer từ bản copy trong `~/.cache/dotfiles` (WSL1 không cho đổi tên thư mục đang có file mở); báo lỗi rõ khi đổi tên `~/.dotfiles` thất bại |
| `b61a3c8` | fzf-tab lấy từ upstream master `24105b1` (sau tag v1.3.0 ba commit): bỏ lệnh `dd bs=1G` đọc phím gõ trước, lệnh này mất 1–3.5 s mỗi lần Tab trên WSL1 |
| `c0664c5`, `d91af72` | prompt 2 dòng (starship và prompt minimal): dòng gõ lệnh nằm riêng, có đủ chiều ngang |
| `4c97568` | test chạy trên GitHub Actions, mỗi row một job; `run.ps1` có thêm `-Row` và `-ListRows` |
| `c202284` | hỗ trợ Debian 12 và 13 (`lib/detect.sh`), thêm row CI `d12`, `d13`; Debian 11, testing/sid và distro phái sinh vẫn bị từ chối |

Full suite ở `0ba8740` và ở `9edb830`: 114 PASS / 0 FAIL. Mỗi task đều qua review và một vòng sửa. Từ `2f80505`, full suite chạy trên CI (xem mục Test bên dưới).

## Kết quả đo trên WSL1 (laptop, terminal mới, PATH Windows 2.9 KB)

Đã trừ overhead của `script` (pty) trên WSL1, khoảng 730–750 ms tuỳ lúc.

| | Trước đợt sửa (`1075061`) | `a91e244` | Giờ (`9edb830`) |
|---|---|---|---|
| `zsh -i` | khoảng 2.3 s | khoảng 5.5 s (lỗi PATH chậm theo bình phương) | **khoảng 650–700 ms** |
| Số lần gọi mise mỗi lần mở shell / mỗi prompt | 2+ | 0 | 0 |
| doctor `zsh startup` | — | 1118 ms | 693 ms (WARN, budget 600 ms) |
| Tab mở danh sách (`ar<Tab>`, fzf-tab) | — | — | khoảng 3.8 s; **khoảng 0.5–0.7 s** từ `b61a3c8` |

Trong khoảng 650 ms còn lại, khoảng 100 ms là `~/.localrc` của bạn. Phần còn lại là compinit, starship, zoxide, fzf (đều đọc từ cache) và chi phí spawn process của WSL1. WSL2 mới giải quyết được triệt để.

`bash -i` khoảng 1.6 s khi đo, trong đó 1.4 s do `~/.localrc` gọi `debug_echo` (không tồn tại). Bạn đã bỏ dòng gọi đó (2026-11-28), chưa đo lại.

## `dotfiles update` trên WSL1: đã sửa và đã thử thật

- Lỗi cũ: `mv: cannot move ~/.dotfiles ... Permission denied` (bash giữ install.sh mở trong lúc đổi tên `~/.dotfiles`).
- Đã thử trên laptop ở `9edb830`: `dotfiles update` exit 0, không còn bản copy hay `~/.dotfiles.old.*` nào sót lại.
- Máy nào còn bản cũ hơn `9edb830` thì lần update đầu tiên vẫn lỗi như trên (vì `bin/dotfiles` cũ vẫn chạy installer ngay trong `~/.dotfiles`). Lần đó cài lại một lần bằng installer tải về:
  `curl -fsSL https://raw.githubusercontent.com/nguyenleminhquan/dotfiles/main/install.sh -o ~/.cache/df-install.sh && DOTFILES_REPO=https://github.com/nguyenleminhquan/dotfiles bash ~/.cache/df-install.sh; rm -f ~/.cache/df-install.sh`.
  Từ lần sau `dotfiles update` chạy bình thường.
- Còn lại (chưa làm): `dotfiles uninstall --purge` cũng xoá `~/.dotfiles` trong lúc đang chạy script nằm trong đó, có thể gặp cùng lỗi trên WSL1. Chưa kiểm chứng.

## Việc của bạn (không phải repo)

- Có thể xoá `~/update-dotfiles.sh` trên node đã migrate.
- Cân nhắc chuyển máy này sang WSL2 (spawn process native, mise activate chỉ khoảng 10 ms).

## Giới hạn đã biết của WSL1 mode

- Ở chế độ cache, `mise shell` / `mise deactivate` chưa dùng được cho tới khi `cd` vào project có config mise.
- Cache không tự làm mới khi đổi biến `MISE_*`, hoặc khi config/installs nằm ngoài `~/.config/mise` và `~/.local/share/mise`. Chạy `dotfiles update` để làm mới.
- Shell non-interactive trên WSL1 dùng version global của tool, không theo `mise.toml` của project (ví dụ cron `cd proj && node`).

## Test: không chạy trên docker-1 nữa

Từ 2026-11-28 không chạy test trên docker-1: IO của test làm etcd của các VM khác bị trễ. Full matrix chạy trên GitHub Actions (`.github/workflows/test.yml`, mỗi row một job), còn lúc đang sửa code thì kiểm tra local (WSL, Docker Desktop).

Run CI đầu tiên (#1, `2f80505`): cả 6 row đều pass. Các job chạy song song, cả run mất khoảng 9 phút; cộng dồn thời gian các job khoảng 33 phút. Run này là lần đầu `b61a3c8` (fzf-tab) và các assert prompt 2 dòng chạy trong container. Log từng case phải đăng nhập GitHub mới xem được.

Run CI cho `c202284` (8 row, có 2 row Debian): cả 9 job đều pass, `d12` mất 473 s, `d13` mất 380 s.

## Để sau (chưa duyệt)

Tag release, plugin 5, cùng vài điểm nhỏ còn lại từ review (ghi trong ledger local).
