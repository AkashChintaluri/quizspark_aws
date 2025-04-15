import React, { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';
import './Login.css';

// API base URL
const API_BASE_URL = 'http://13.200.253.50:80';

function TeacherLogin() {
    const navigate = useNavigate();
    const [formData, setFormData] = useState({ username: '', password: '' });
    const [isLoading, setIsLoading] = useState(false);
    const [showPopup, setShowPopup] = useState(false);
    const [errorMessage, setErrorMessage] = useState('');

    useEffect(() => {
        if (showPopup) {
            const timer = setTimeout(() => {
                setShowPopup(false);
                navigate('/teacher-dashboard');
            }, 2000);
            return () => clearTimeout(timer);
        }
    }, [showPopup, navigate]);

    const handleInputChange = (e) => {
        const { id, value } = e.target;
        setFormData(prev => ({ ...prev, [id]: value }));
    };

    const handleSubmit = async (e) => {
        e.preventDefault();
        setIsLoading(true);
        setErrorMessage('');

        try {
            const response = await axios.post(`${API_BASE_URL}/login`, {
                ...formData,
                userType: 'teacher'
            });

            if (response.data.success) {
                localStorage.setItem('user', JSON.stringify(response.data.user));
                setShowPopup(true);
            } else {
                setErrorMessage('Invalid username or password');
            }
        } catch (error) {
            const serverError = error.response?.data?.error || error.message;
            setErrorMessage(serverError || 'Login failed. Please try again.');
            console.error('Login error:', error);
        } finally {
            setIsLoading(false);
        }
    };

    return (
        <div className="login">
            <div className="login-content">
                <h2>Teacher Login</h2>
                <form className="login-form" onSubmit={handleSubmit}>
                    <div className="form-group">
                        <input
                            type="text"
                            id="username"
                            value={formData.username}
                            onChange={handleInputChange}
                            required
                            placeholder="Username"
                            autoComplete="username"
                            disabled={isLoading}
                        />
                    </div>
                    <div className="form-group">
                        <input
                            type="password"
                            id="password"
                            value={formData.password}
                            onChange={handleInputChange}
                            required
                            placeholder="Password"
                            autoComplete="current-password"
                            disabled={isLoading}
                        />
                    </div>

                    {errorMessage && <div className="error-message">{errorMessage}</div>}

                    <button
                        type="submit"
                        className="login-button"
                        disabled={isLoading}
                    >
                        {isLoading ? 'Logging In...' : 'Login'}
                    </button>
                </form>
            </div>

            {showPopup && (
                <div className="popup success">
                    ✔️ Login successful! Redirecting to dashboard...
                </div>
            )}
        </div>
    );
}

export default TeacherLogin;
