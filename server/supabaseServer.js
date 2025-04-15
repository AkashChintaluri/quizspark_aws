import express from 'express';
import { createClient } from '@supabase/supabase-js';
import cors from 'cors';
import dotenv from 'dotenv';

dotenv.config();

const app = express();

// CORS configuration
const corsOptions = {
  origin: process.env.CORS_ORIGIN || 'http://localhost:5173',
  credentials: true
};
app.use(cors(corsOptions));

app.use(express.json());

// Validate required environment variables
const requiredEnvVars = ['SUPABASE_URL', 'SUPABASE_KEY'];
for (const envVar of requiredEnvVars) {
  if (!process.env[envVar]) {
    console.error(`Missing required environment variable: ${envVar}`);
    process.exit(1);
  }
}

// Initialize Supabase client
const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_KEY,
  {
    auth: {
      autoRefreshToken: true,
      persistSession: true
    }
  }
);

// Test the Supabase connection
async function testConnection() {
  try {
    const { data, error } = await supabase.from('student_login').select('*').limit(1);
    if (error) throw error;
    console.log('Connected to Supabase');
    startServer();
  } catch (error) {
    console.error('Error connecting to Supabase:', error);
    process.exit(1);
  }
}

function startServer() {
  // Authentication middleware
  const authenticateUser = async (req, res, next) => {
    const token = req.headers.authorization?.split(' ')[1];
    if (!token) {
      return res.status(401).json({ error: 'No token provided' });
    }

    try {
      const { data: { user }, error } = await supabase.auth.getUser(token);
      if (error) throw error;
      req.user = user;
      next();
    } catch (error) {
      res.status(401).json({ error: 'Invalid token' });
    }
  };

  // Custom business logic endpoints that can't be handled by Supabase directly
  app.post('/api/quizzes/submit', authenticateUser, async (req, res) => {
    const { quiz_id, answers, score } = req.body;
    const student_id = req.user.id;

    try {
      const { data, error } = await supabase
        .from('quiz_submissions')
        .insert([{
          student_id,
          quiz_id,
          answers,
          score
        }])
        .select();

      if (error) throw error;

      res.status(201).json({
        message: 'Quiz submitted successfully',
        submissionId: data[0].id
      });
    } catch (error) {
      console.error('Error submitting quiz:', error);
      res.status(500).json({ message: 'Failed to submit quiz', error: error.message });
    }
  });

  // Get quiz submissions with student details
  app.get('/api/quizzes/submissions/:quiz_id', authenticateUser, async (req, res) => {
    const { quiz_id } = req.params;

    try {
      const { data, error } = await supabase
        .from('quiz_submissions')
        .select(`
          *,
          student_login (
            username
          )
        `)
        .eq('quiz_id', quiz_id);

      if (error) throw error;

      res.json(data);
    } catch (error) {
      console.error('Error fetching submissions:', error);
      res.status(500).json({ message: 'Failed to fetch submissions', error: error.message });
    }
  });

  // Get teacher's quizzes with submission counts
  app.get('/api/quizzes/teacher/:teacher_id', authenticateUser, async (req, res) => {
    const { teacher_id } = req.params;

    try {
      const { data: quizzes, error: quizzesError } = await supabase
        .from('quizzes')
        .select('*')
        .eq('created_by', teacher_id);

      if (quizzesError) throw quizzesError;

      // Get submission counts for each quiz
      const quizzesWithSubmissions = await Promise.all(
        quizzes.map(async (quiz) => {
          const { count, error: countError } = await supabase
            .from('quiz_submissions')
            .select('*', { count: 'exact', head: true })
            .eq('quiz_id', quiz.quiz_id);

          if (countError) throw countError;

          return {
            ...quiz,
            submission_count: count
          };
        })
      );

      res.json(quizzesWithSubmissions);
    } catch (error) {
      console.error('Error fetching quizzes:', error);
      res.status(500).json({ message: 'Failed to fetch quizzes', error: error.message });
    }
  });

  // Start the server
  const PORT = process.env.PORT || 3000;
  app.listen(PORT, () => {
    console.log(`Server running in ${process.env.NODE_ENV} mode on port ${PORT}`);
    console.log(`CORS enabled for origin: ${process.env.CORS_ORIGIN}`);
  });
}

testConnection(); 