// ╔═══════════════════════════════════════════════════════════════╗
// ║  SysOpt.Breakout — Atari Breakout Easter Egg Engine          ║
// ║  DrawingVisual renderer — zero layout, zero UIElement GC     ║
// ║  © 2026 Danew Malavita — github.com/danewmalavita            ║
// ╚═══════════════════════════════════════════════════════════════╝

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace SysOpt.Breakout
{
    // ── Minimal data struct — no UIElement, no Rectangle ──
    public class Brick
    {
        public double X, Y, W, H;
        public int Points, Row;
        public bool Alive;
    }

    // ══════════════════════════════════════════════════════════════
    //  GameHost — single DrawingVisual, bypasses WPF layout system
    // ══════════════════════════════════════════════════════════════
    public class GameHost : FrameworkElement
    {
        DrawingVisual visual;

        public GameHost()
        {
            visual = new DrawingVisual();
            AddVisualChild(visual);
        }

        protected override int VisualChildrenCount { get { return 1; } }
        protected override Visual GetVisualChild(int index) { return visual; }

        public DrawingContext Open() { return visual.RenderOpen(); }
    }

    // ══════════════════════════════════════════════════════════════
    //  BreakoutEngine — self-contained, vsync-locked, delta-time
    // ══════════════════════════════════════════════════════════════
    public class BreakoutEngine
    {
        // ── Dimensions ──
        const double CW = 480, CH = 400;
        const double BALL_R = 5;          // radius
        const double PAD_W = 80, PAD_H = 12, PAD_Y = 370;

        // ── Grid ──
        const int ROWS = 6, COLS = 10;
        const double BW = 44, BH = 16, BGAP = 2, BTOP = 45;

        // ── Ball state ──
        double bx, by, vx, vy;
        const double BASE_SPEED = 200.0; // pixels per second

        // ── Paddle ──
        double px;

        // ── Game state ──
        int score, lives, aliveCount;
        double speedMul;
        bool playing, gameOver, won;

        // ── Timing (locked 60 fps) ──
        long lastTick;
        static readonly double TicksPerSec = (double)System.Diagnostics.Stopwatch.Frequency;
        System.Diagnostics.Stopwatch clock;
        const double TARGET_FPS = 60.0;
        const double FRAME_TIME = 1.0 / TARGET_FPS;
        double accumulator;

        // ── Rendering ──
        Canvas hostCanvas;
        GameHost host;
        Brush[] rowBrushes;
        Brush brBg, brBall, brPaddle, brHud, brAccent, brBorder;
        Brush brGameOver, brWin;
        Pen penBorder;
        Typeface tfHud, tfMsg;

        // ── Cached HUD text ──
        int cachedScore, cachedLives;
        FormattedText ftHud;
        bool hudDirty;
        double dpiScale;

        // ── Localized strings ──
        string lClickToPlay, lClickContinue, lGameOver, lYouWin, lScore, lLives, lPts;

        // ── Row colors ──
        static readonly string[] DefaultRowColors = {
            "#FC8181","#F6AD55","#F6E05E","#68D391","#4FD1C5","#A47CFF"
        };

        List<Brick> bricks;

        // ══════════════════════════════════════════════════════════
        //  Init — call once, engine takes over
        // ══════════════════════════════════════════════════════════
        public void Init(Canvas gameCanvas, string cBg, string cBall,
                         string cPaddle, string cHud, string cAccent,
                         string cBorder,
                         string sClickToPlay, string sClickContinue,
                         string sGameOver, string sYouWin,
                         string sScore, string sLives, string sPts)
        {
            hostCanvas = gameCanvas;

            // ── Strings ──
            lClickToPlay  = sClickToPlay  ?? "Click to Play!";
            lClickContinue= sClickContinue?? "Click to continue";
            lGameOver     = sGameOver     ?? "GAME OVER";
            lYouWin       = sYouWin       ?? "YOU WIN!";
            lScore        = sScore        ?? "SCORE";
            lLives        = sLives        ?? "LIVES";
            lPts          = sPts          ?? "pts";

            // ── Brushes (all frozen for thread safety + perf) ──
            var bc = new BrushConverter();
            brBg      = Freeze((Brush)bc.ConvertFromString(cBg));
            brBall    = Freeze((Brush)bc.ConvertFromString(cBall));
            brPaddle  = Freeze((Brush)bc.ConvertFromString(cPaddle));
            brHud     = Freeze((Brush)bc.ConvertFromString(cHud));
            brAccent  = Freeze((Brush)bc.ConvertFromString(cAccent));
            brBorder  = Freeze((Brush)bc.ConvertFromString(cBorder));
            brGameOver= Freeze((Brush)bc.ConvertFromString("#FC8181"));
            brWin     = Freeze((Brush)bc.ConvertFromString("#68D391"));

            penBorder = new Pen(brBorder, 1);
            penBorder.Freeze();

            rowBrushes = new Brush[ROWS];
            for (int i = 0; i < ROWS; i++)
                rowBrushes[i] = Freeze((Brush)bc.ConvertFromString(DefaultRowColors[i]));

            // ── Typefaces (reusable, zero alloc) ──
            tfHud = new Typeface(new FontFamily("Consolas"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
            tfMsg = new Typeface(new FontFamily("Segoe UI"),  FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);

            // ── Build bricks (data only, no UIElements) ──
            bricks = new List<Brick>(ROWS * COLS);
            double totalW = COLS * (BW + BGAP) - BGAP;
            double offX = Math.Floor((CW - totalW) / 2);
            for (int r = 0; r < ROWS; r++)
            {
                for (int c = 0; c < COLS; c++)
                {
                    bricks.Add(new Brick {
                        X = c * (BW + BGAP) + offX,
                        Y = r * (BH + BGAP) + BTOP,
                        W = BW, H = BH,
                        Points = (ROWS - r) * 10,
                        Row = r, Alive = true
                    });
                }
            }
            aliveCount = bricks.Count;

            // ── Create GameHost (single DrawingVisual, no layout) ──
            host = new GameHost();
            host.Width = CW;
            host.Height = CH;
            host.IsHitTestVisible = false;
            hostCanvas.Children.Add(host);
            Canvas.SetLeft(host, 0);
            Canvas.SetTop(host, 0);

            // ── Initial state ──
            ResetState();

            // ── Input (on the canvas, not the host) ──
            hostCanvas.MouseMove += OnMouseMove;
            hostCanvas.MouseLeftButtonDown += OnClick;
            hostCanvas.Focusable = true;
            hostCanvas.Focus();

            // ── Cache DPI once (avoids per-frame VisualTreeHelper call) ──
            dpiScale = VisualTreeHelper.GetDpi(host).PixelsPerDip;

            // ── Start render loop ──
            clock = System.Diagnostics.Stopwatch.StartNew();
            lastTick = clock.ElapsedTicks;
            accumulator = 0;
            hudDirty = true;
            CompositionTarget.Rendering += OnFrame;

            // Draw first frame
            DrawFrame();
        }

        public void Stop()
        {
            CompositionTarget.Rendering -= OnFrame;
            if (clock != null) clock.Stop();
        }

        // ── Helpers ──
        static Brush Freeze(Brush b) { b.Freeze(); return b; }

        void ResetState()
        {
            score = 0; lives = 3; speedMul = 1.0;
            bx = CW / 2; by = PAD_Y - 40;
            px = (CW - PAD_W) / 2;
            vx = 0.7; vy = -1.0; // normalized direction
            NormalizeVelocity();
            gameOver = false; won = false; playing = false;
            aliveCount = bricks.Count;
            for (int i = 0; i < bricks.Count; i++)
                bricks[i].Alive = true;
            hudDirty = true;
            cachedScore = -1;
        }

        void NormalizeVelocity()
        {
            double len = Math.Sqrt(vx * vx + vy * vy);
            if (len > 0) { vx /= len; vy /= len; }
        }

        // ══════════════════════════════════════════════════════════
        //  Input handlers
        // ══════════════════════════════════════════════════════════
        void OnMouseMove(object sender, MouseEventArgs e)
        {
            var pos = e.GetPosition(hostCanvas);
            px = Math.Max(0, Math.Min(pos.X - PAD_W / 2, CW - PAD_W));
        }

        void OnClick(object sender, MouseButtonEventArgs e)
        {
            if (gameOver || won) { ResetState(); DrawFrame(); return; }
            if (!playing)
            {
                playing = true;
            }
        }

        // ══════════════════════════════════════════════════════════
        //  Frame loop — fixed 60 fps timestep with accumulator
        //  Decouples physics from monitor refresh rate
        // ══════════════════════════════════════════════════════════
        void OnFrame(object sender, EventArgs e)
        {
            long now = clock.ElapsedTicks;
            double dt = (now - lastTick) / TicksPerSec;
            lastTick = now;

            // Clamp dt to avoid spiral of death on lag spikes
            if (dt > 0.05) dt = 0.05;

            accumulator += dt;

            // Skip frame if not enough time has passed (locked 60fps)
            if (accumulator < FRAME_TIME) return;

            // Consume one tick; reset if too far behind (prevents catch-up stutter)
            accumulator -= FRAME_TIME;
            if (accumulator > FRAME_TIME * 2) accumulator = 0;

            if (playing) UpdatePhysics(FRAME_TIME);

            DrawFrame();
        }

        // ══════════════════════════════════════════════════════════
        //  Physics — all delta-time based (pixels/second)
        // ══════════════════════════════════════════════════════════
        void UpdatePhysics(double dt)
        {
            double spd = BASE_SPEED * speedMul * dt;
            bx += vx * spd;
            by += vy * spd;

            // Wall bounce
            if (bx <= 0)             { vx = Math.Abs(vx);  bx = 0; }
            if (bx >= CW - BALL_R*2) { vx = -Math.Abs(vx); bx = CW - BALL_R*2; }
            if (by <= 0)             { vy = Math.Abs(vy);  by = 0; }

            // Ball out bottom
            if (by >= CH)
            {
                lives--;
                playing = false;
                if (lives <= 0) gameOver = true;
                else
                {
                    bx = px + PAD_W / 2; by = PAD_Y - 40;
                    vx = 0.7; vy = -1.0;
                    NormalizeVelocity();
                }
                hudDirty = true;
                return;
            }

            // Paddle collision
            double ballBottom = by + BALL_R * 2;
            double ballRight  = bx + BALL_R * 2;
            if (ballBottom >= PAD_Y && ballBottom <= PAD_Y + PAD_H + 4 &&
                ballRight >= px && bx <= px + PAD_W && vy > 0)
            {
                vy = -1.0;
                double hitRatio = (bx + BALL_R - px) / PAD_W;
                vx = (hitRatio - 0.5) * 2.5;
                NormalizeVelocity();
                by = PAD_Y - BALL_R * 2;
            }

            // Brick collision
            for (int i = 0; i < bricks.Count; i++)
            {
                Brick b = bricks[i];
                if (!b.Alive) continue;
                if (bx + BALL_R*2 > b.X && bx < b.X + b.W &&
                    by + BALL_R*2 > b.Y && by < b.Y + b.H)
                {
                    b.Alive = false;
                    aliveCount--;
                    vy = -vy;
                    score += b.Points;
                    speedMul = 1.0 + Math.Floor(score / 300.0) * 0.1;
                    hudDirty = true;
                    break;
                }
            }

            // Win check
            if (aliveCount <= 0)
            {
                playing = false;
                won = true;
                hudDirty = true;
            }
        }

        // ══════════════════════════════════════════════════════════
        //  Draw — single DrawingContext, zero UIElement, zero layout
        // ══════════════════════════════════════════════════════════
        void DrawFrame()
        {
            using (DrawingContext dc = host.Open())
            {
                // Background
                dc.DrawRectangle(brBg, null, new Rect(0, 0, CW, CH));

                // HUD separator
                dc.DrawLine(penBorder, new Point(0, 30), new Point(CW, 30));

                // HUD text (cached — only rebuild when dirty)
                if (hudDirty || cachedScore != score || cachedLives != lives)
                {
                    string hudStr = lScore + " " + score + "    " + lLives + " " + lives;
                    ftHud = new FormattedText(hudStr, CultureInfo.InvariantCulture,
                        FlowDirection.LeftToRight, tfHud, 12, brHud, dpiScale);
                    cachedScore = score;
                    cachedLives = lives;
                    hudDirty = false;
                }
                dc.DrawText(ftHud, new Point(10, 8));

                // Bricks
                for (int i = 0; i < bricks.Count; i++)
                {
                    Brick b = bricks[i];
                    if (!b.Alive) continue;
                    dc.DrawRoundedRectangle(rowBrushes[b.Row], null,
                        new Rect(b.X, b.Y, b.W, b.H), 3, 3);
                }

                // Ball
                dc.DrawEllipse(brBall, null,
                    new Point(bx + BALL_R, by + BALL_R), BALL_R, BALL_R);

                // Paddle
                dc.DrawRoundedRectangle(brPaddle, null,
                    new Rect(px, PAD_Y, PAD_W, PAD_H), 6, 6);

                // Center message
                if (!playing)
                {
                    string msgStr;
                    Brush msgBrush;
                    if (gameOver)
                    {
                        msgStr = lGameOver + "  \u2014  " + score + " " + lPts;
                        msgBrush = brGameOver;
                    }
                    else if (won)
                    {
                        msgStr = lYouWin + "  \u2014  " + score + " " + lPts;
                        msgBrush = brWin;
                    }
                    else if (lives < 3 && lives > 0)
                    {
                        msgStr = "x" + lives + "  \u2014  " + lClickContinue;
                        msgBrush = brAccent;
                    }
                    else
                    {
                        msgStr = lClickToPlay;
                        msgBrush = brAccent;
                    }

                    var ft = new FormattedText(msgStr, CultureInfo.InvariantCulture,
                        FlowDirection.LeftToRight, tfMsg, 18, msgBrush, dpiScale);
                    ft.TextAlignment = TextAlignment.Center;
                    dc.DrawText(ft, new Point(CW / 2, Math.Floor(CH / 2) - 10));
                }
            }
        }
    }
}
